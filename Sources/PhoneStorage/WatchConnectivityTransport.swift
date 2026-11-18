import Foundation
import RecorderContracts

#if os(iOS) && canImport(WatchConnectivity)
import WatchConnectivity

/// Thin iOS-only transport seam adapting `WCSession.transferFile` deliveries
/// to `PhoneReceiveService`. Kept deliberately thin — all durability logic
/// lives in the service — so the receive pipeline stays exercisable without a
/// paired Watch.
///
/// Wire contract (aligned with C1's `WCSessionTransport`/`InboundCommandDecoder`,
/// verified 2026-11-18 — see S1 handoff):
/// - Incoming `WCSessionFile.metadata`: `["chunkID": String, "sessionID": String,
///   "sequenceNumber": Int, "fileName": String, "chunk": Data(JSON
///   AudioChunkMetadata)]`. `"chunkMetadata"` (Data or String) is accepted as
///   an alternate key for forward compatibility.
/// - Acks: `["type": "ack", "ack": Data(JSON TransferAcknowledgment)]` via
///   `sendMessage` when reachable, else queued via `transferUserInfo`.
/// - Deletion propagation: `["type": "discard", "chunkID": "<uuid>"]` per
///   tombstoned chunk via `transferUserInfo` so the Watch drops its outbox
///   entry and file copy. Session/conversation intents propagate through
///   their cascaded chunk tombstones.
/// - Session truth (I1): `["type": "session", "session": Data(JSON
///   RecordingSession)]` — the watch app relays each `stateUpdates()`
///   snapshot via `updateApplicationContext` (latest-value semantics match
///   the sessions mirror); the same shape is also accepted on `userInfo`
///   deliveries. Received snapshots feed `archiveStore.upsertSession`.
/// `@unchecked Sendable`: every stored property is immutable, `WCSession`
/// calls are documented thread-safe (delegate callbacks arrive on the main
/// thread; send/transfer calls may be made from any queue), and `FileManager`
/// is thread-safe. Needed so ingest/ack work can hop onto `Task`s.
public final class WatchConnectivityReceiveTransport: NSObject, @unchecked Sendable {
    private let receiveService: PhoneReceiveService
    private let archiveStore: SQLiteArchiveStore
    private let session: WCSession
    private let fileManager = FileManager.default

    public enum Keys {
        public static let chunk = "chunk"
        public static let chunkMetadata = "chunkMetadata"
        public static let messageType = "type"
        public static let typeAck = "ack"
        public static let typeDiscard = "discard"
        public static let typeSession = "session"
        public static let ack = "ack"
        public static let chunkID = "chunkID"
        public static let session = "session"
    }

    public init(
        receiveService: PhoneReceiveService,
        session: WCSession = .default
    ) {
        self.receiveService = receiveService
        self.archiveStore = receiveService.archiveStore
        self.session = session
        super.init()
    }

    /// Activates the WCSession. Returns false when WatchConnectivity is
    /// unsupported on this device (e.g. no paired Watch possible) — callers
    /// should keep the data path working regardless.
    @discardableResult
    public func activate() -> Bool {
        guard WCSession.isSupported() else { return false }
        session.delegate = self
        session.activate()
        return true
    }

    /// Pushes all not-yet-propagated deletion intents to the Watch. Called on
    /// activation/reachability changes and may be invoked by the app after
    /// recording a deletion. Chunk intents map 1:1 to `discard` commands;
    /// session/conversation intents flush through their cascaded chunk
    /// tombstones and are marked propagated once those are queued.
    public func flushDeletionIntents() {
        Task {
            guard let intents = try? await archiveStore.unpropagatedDeletionIntents(),
                  !intents.isEmpty else { return }
            for intent in intents where intent.target == .chunk {
                session.transferUserInfo([
                    Keys.messageType: Keys.typeDiscard,
                    Keys.chunkID: intent.targetID.uuidString,
                ])
            }
            try? await archiveStore.markDeletionIntentsPropagated(intents.map(\.id))
        }
    }

    // MARK: - Ack channel

    private func send(acknowledgment: TransferAcknowledgment) {
        guard let data = try? JSONEncoder().encode(acknowledgment) else { return }
        let message: [String: Any] = [Keys.messageType: Keys.typeAck, Keys.ack: data]
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { [weak self] _ in
                // sendMessage can fail despite reachability — queue it so the
                // Watch still gets the ack and can drop its copy.
                self?.session.transferUserInfo(message)
            }
        } else {
            session.transferUserInfo(message)
        }
    }

    private func emitTransferDiag(
        name: String,
        severity: DiagnosticsSeverity = .info,
        payload: [String: String]
    ) {
        Task {
            await archiveStore.record(DiagnosticsEvent(
                subsystem: .transfer,
                severity: severity,
                name: name,
                payload: payload
            ))
        }
    }

    /// Tolerant decode of the chunk metadata entry: C1 sends `"chunk"` as
    /// JSON `Data`; `"chunkMetadata"` (Data or UTF-8 String) is also accepted.
    static func decodeChunkMetadata(
        from metadata: [String: Any]?
    ) -> AudioChunkMetadata? {
        for key in [Keys.chunk, Keys.chunkMetadata] {
            guard let value = metadata?[key] else { continue }
            let data: Data? = switch value {
            case let data as Data: data
            case let string as String: Data(string.utf8)
            default: nil
            }
            if let data,
               let decoded = try? JSONDecoder().decode(AudioChunkMetadata.self, from: data) {
                return decoded
            }
        }
        return nil
    }
}

extension WatchConnectivityReceiveTransport: WCSessionDelegate {
    /// `fileURL` is only valid for the duration of this callback, so the file
    /// is copied into our `incoming/` landing area synchronously here; the
    /// durable pipeline (verify→move→register→ack) runs after return.
    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let layout = archiveStore.storageLayout
        let landing = layout.incomingDirectory
            .appendingPathComponent("wc-\(UUID().uuidString).part")
        do {
            try fileManager.createDirectory(
                at: layout.incomingDirectory, withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: file.fileURL, to: landing)
        } catch {
            emitTransferDiag(
                name: "transfer.landing_failed",
                severity: .error,
                payload: ["file": file.fileURL.lastPathComponent]
            )
            return
        }

        guard let metadata = Self.decodeChunkMetadata(from: file.metadata) else {
            // Undecodable metadata → quarantine, no ack (cannot even identify
            // the chunk; the sender's retry will re-deliver).
            let quarantined = layout.quarantineDirectory
                .appendingPathComponent("undecodable-\(landing.lastPathComponent)")
            try? fileManager.moveItem(at: landing, to: quarantined)
            emitTransferDiag(
                name: "transfer.metadata_undecodable",
                severity: .error,
                payload: ["file": file.fileURL.lastPathComponent]
            )
            return
        }

        Task {
            do {
                let ack = try await receiveService.ingestReceivedFile(
                    at: landing, metadata: metadata
                )
                send(acknowledgment: ack)
                emitTransferDiag(name: "transfer.ack_sent", payload: [
                    "chunk_id": metadata.id.uuidString,
                    "status": ack.status.rawValue,
                ])
            } catch RecorderError.integrityMismatch {
                send(acknowledgment: TransferAcknowledgment(
                    chunkID: metadata.id,
                    sessionID: metadata.sessionID,
                    status: .failed,
                    acknowledgedAt: Date(),
                    verifiedSHA256Hex: "",
                    storedByteCount: 0
                ))
            } catch {
                send(acknowledgment: TransferAcknowledgment(
                    chunkID: metadata.id,
                    sessionID: metadata.sessionID,
                    status: .failed,
                    acknowledgedAt: Date(),
                    verifiedSHA256Hex: "",
                    storedByteCount: 0
                ))
                emitTransferDiag(
                    name: "transfer.ingest_failed",
                    severity: .error,
                    payload: ["chunk_id": metadata.id.uuidString]
                )
            }
        }
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            flushDeletionIntents()
        }
        emitTransferDiag(name: "transfer.wcsession_activation", payload: [
            "state": "\(activationState.rawValue)",
            "error": error.map { "\($0)" } ?? "none",
        ])
    }

    /// Watch→phone session truth (I1): the watch relays every
    /// `stateUpdates()` snapshot as applicationContext, so the latest
    /// `RecordingSession` arrives without us polling.
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleSessionPayload(applicationContext)
    }

    /// Same payload shape accepted on `userInfo` deliveries — the decoder is
    /// shared so either channel lands the session mirror row.
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleSessionPayload(userInfo)
    }

    private func handleSessionPayload(_ dictionary: [String: Any]) {
        guard dictionary[Keys.messageType] as? String == Keys.typeSession,
              let data = dictionary[Keys.session] as? Data,
              let snapshot = try? JSONDecoder().decode(RecordingSession.self, from: data)
        else { return }
        Task {
            do {
                try await archiveStore.upsertSession(snapshot)
                emitTransferDiag(name: "transfer.session_received", payload: [
                    "session_id": snapshot.id.uuidString,
                    "state": snapshot.state.rawValue,
                ])
            } catch {
                emitTransferDiag(
                    name: "transfer.session_upsert_failed",
                    severity: .error,
                    payload: ["session_id": snapshot.id.uuidString]
                )
            }
        }
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        // Per API contract, re-activate after switching Watches etc.
        session.activate()
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            flushDeletionIntents()
        }
    }

    public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        if let error {
            emitTransferDiag(
                name: "transfer.outgoing_error",
                severity: .warning,
                payload: ["file": fileTransfer.file.fileURL.lastPathComponent,
                          "error": "\(error)"]
            )
        }
    }
}
#endif
