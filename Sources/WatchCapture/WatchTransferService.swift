import Foundation
import RecorderContracts

/// One persisted outbox row. `status` maps to the contract's `TransferStatus`;
/// the file on disk is the source of truth until the phone's durable ack.
struct OutboxEntry: Codable, Sendable {
    var chunk: AudioChunkMetadata
    var status: TransferStatus
    var enqueuedAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?
}

/// Atomic JSON persistence for the outbox — same tmp-write + rename discipline
/// as the session store so a crash mid-write never tears queue state.
struct OutboxStore: Sendable {
    let file: URL

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func load() -> [OutboxEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([OutboxEntry].self, from: data)) ?? []
    }

    func save(_ entries: [OutboxEntry]) throws {
        try encoder.encode(entries).write(to: file, options: .atomic)
    }
}

/// Durable, restart-safe watch-side outbox implementing
/// `WatchTransferServiceProtocol`. Chunks enqueue on finalization, send over
/// the `WatchChunkTransport` seam (WCSession on watchOS), track
/// queued → inFlight → awaitingAcknowledgment → acknowledged, and delete the
/// watch copy only after a verified durable ack — or explicit deletion.
///
/// Restart rule: entries persisted as `inFlight`/`awaitingAcknowledgment` are
/// demoted to `queued` at launch. A lost `WCSessionFileTransfer` object or a
/// lost ack otherwise strands the chunk forever; resending is safe because
/// the receive contract requires the phone to deduplicate.
public actor WatchTransferService: WatchTransferServiceProtocol {
    /// Send attempts plus phone rejections past this bound park the entry
    /// `.failed` until the next activation — the queue never silently drops
    /// an unacknowledged chunk, and a permanently-rejected chunk never
    /// resends forever.
    static let maxAttempts = 12

    private let paths: CapturePaths
    private let store: OutboxStore
    private let transport: any WatchChunkTransport
    private let diagnostics: WatchDiagnostics

    private var entries: [OutboxEntry] = []
    /// Assigned inside the nonisolated initializer; touched only by
    /// init/deinit afterwards, so bypassing isolation is race-free.
    private nonisolated(unsafe) var transportTask: Task<Void, Never>?

    /// App-facing initializer: real platform transport (WCSession on watchOS).
    public init(directory: URL? = nil, diagnostics: WatchDiagnostics? = nil) {
        self.init(directory: directory, transport: nil, diagnostics: diagnostics)
    }

    /// Transport-injecting initializer — the seam stays internal per the
    /// lane brief; the app and I1 use the public initializer above.
    init(
        directory: URL? = nil,
        transport: (any WatchChunkTransport)?,
        diagnostics: WatchDiagnostics? = nil
    ) {
        var paths = directory.flatMap { try? CapturePaths.makeCustom(root: $0) }
            ?? (try? CapturePaths.makeDefault())
        if paths == nil {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("WatchCapture-\(UUID().uuidString)", isDirectory: true)
            paths = (try? CapturePaths.makeCustom(root: tmp)) ?? CapturePaths(root: tmp)
        }
        let resolved = paths!
        self.paths = resolved
        self.store = OutboxStore(file: resolved.outboxFile)
        self.diagnostics = diagnostics ?? WatchDiagnostics(directory: resolved.root)
        #if canImport(WatchConnectivity)
        self.transport = transport ?? WCSessionTransport()
        #else
        self.transport = transport ?? UnavailableChunkTransport()
        #endif
        entries = store.load()
        // Relaunch bookkeeping: wire-side state dies with the process, so any
        // entry mid-flight goes back to queued for a dedupe-safe resend.
        var demoted = 0
        for index in entries.indices {
            let status = entries[index].status
            if status == .inFlight || status == .awaitingAcknowledgment {
                entries[index].status = .queued
                demoted += 1
            }
        }
        if demoted > 0 { try? store.save(entries) }
        self.diagnostics.emit(.lifecycle, name: "outbox-restored", payload: [
            "entries": "\(entries.count)",
            "demoted": "\(demoted)",
            "transport": String(describing: type(of: self.transport))
        ])
        self.transportTask = makeTransportPump(transport: self.transport)
    }

    /// Nonisolated so it may be invoked from the nonisolated initializer —
    /// the `self` capture happens here, not in init.
    private nonisolated func makeTransportPump(
        transport: any WatchChunkTransport
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in transport.events {
                guard let self else { return }
                await self.handleTransportEvent(event)
            }
        }
    }

    deinit {
        transportTask?.cancel()
    }

    // MARK: - Activation / pumping (public, beyond the contract)

    /// Activates the transport then drains the queue. Safe to call again on
    /// every foregrounding; activation failure is logged, not thrown. Each
    /// activation is a fresh retry window for entries parked as `.failed`,
    /// and reconciles the capture manifest against the outbox so a chunk
    /// persisted but never enqueued (crash in the seal→enqueue window) is
    /// re-queued here.
    public func activate() async {
        do {
            try await transport.activate()
            diagnostics.emit(.transfer, name: "transport-activated")
        } catch {
            diagnostics.emit(.transfer, name: "transport-activate-failed",
                             severity: .warning, payload: ["error": "\(error)"])
        }
        var reset = false
        for index in entries.indices where entries[index].status == .failed {
            entries[index].attemptCount = 0
            entries[index].status = .queued
            reset = true
        }
        if reset { persist() }
        reconcileManifestsWithOutbox()
        await pump()
    }

    /// Drains queued/failed entries through the transport. Re-entrant-safe;
    /// called automatically on enqueue, activation, and reachability.
    public func processOutbox() async {
        await pump()
    }

    // MARK: - WatchTransferServiceProtocol

    public func enqueueForTransfer(_ chunk: AudioChunkMetadata) async throws {
        guard !entries.contains(where: { $0.chunk.id == chunk.id }) else {
            return // idempotent — a re-enqueued chunk is already tracked
        }
        entries.append(OutboxEntry(
            chunk: chunk,
            status: .queued,
            enqueuedAt: Date(),
            attemptCount: 0,
            lastAttemptAt: nil,
            lastError: nil
        ))
        persist()
        diagnostics.emit(.transfer, name: "chunk-enqueued", payload: [
            "chunkID": chunk.id.uuidString,
            "seq": "\(chunk.integrity.sequenceNumber)",
            "bytes": "\(chunk.integrity.byteCount)"
        ])
        await pump()
    }

    public func chunksAwaitingAcknowledgment(sessionID: UUID) async -> [AudioChunkMetadata] {
        entries
            .filter { $0.chunk.sessionID == sessionID }
            .sorted { $0.chunk.integrity.sequenceNumber < $1.chunk.integrity.sequenceNumber }
            .map(\.chunk)
    }

    public func markInFlight(chunkID: UUID) async throws {
        guard let index = entries.firstIndex(where: { $0.chunk.id == chunkID }) else {
            throw RecorderError.notFound
        }
        entries[index].status = .inFlight
        persist()
    }

    /// Durable phone ack retires the chunk — the only path (besides explicit
    /// deletion) that deletes the watch copy. Digest/size are re-verified
    /// against the ack before anything is removed.
    public func apply(acknowledgment: TransferAcknowledgment) async throws {
        guard acknowledgment.status == .acknowledged else {
            guard acknowledgment.status == .failed else {
                diagnostics.emit(.transfer, name: "ack-non-acknowledged", severity: .warning,
                                 payload: ["chunkID": acknowledgment.chunkID.uuidString,
                                           "status": acknowledgment.status.rawValue])
                return
            }
            guard let index = entries.firstIndex(where: { $0.chunk.id == acknowledgment.chunkID }) else {
                diagnostics.emit(.transfer, name: "ack-unknown-chunk", severity: .warning,
                                 payload: ["chunkID": acknowledgment.chunkID.uuidString])
                return
            }
            // The phone rejected this delivery outright. Count it against the
            // same budget sends use: a transient rejection still self-heals
            // (ack-timeout requeues, a later .acknowledged retires the row),
            // but a permanently-rejected chunk parks .failed once the budget
            // is spent instead of resending ~144×/day forever.
            entries[index].attemptCount += 1
            entries[index].lastError = "ack-rejected"
            if entries[index].attemptCount >= Self.maxAttempts {
                entries[index].status = .failed
                diagnostics.emit(.transfer, name: "chunk-parked-rejected", severity: .error,
                                 payload: ["chunkID": acknowledgment.chunkID.uuidString,
                                           "attempts": "\(entries[index].attemptCount)"])
            } else {
                diagnostics.emit(.transfer, name: "ack-rejected", severity: .warning,
                                 payload: ["chunkID": acknowledgment.chunkID.uuidString,
                                           "attempts": "\(entries[index].attemptCount)"])
            }
            persist()
            return
        }
        guard let index = entries.firstIndex(where: { $0.chunk.id == acknowledgment.chunkID }) else {
            diagnostics.emit(.transfer, name: "ack-unknown-chunk", severity: .warning,
                             payload: ["chunkID": acknowledgment.chunkID.uuidString])
            return
        }
        let chunk = entries[index].chunk
        let digestMatches = acknowledgment.verifiedSHA256Hex == chunk.integrity.sha256Hex
        let sizeMatches = acknowledgment.storedByteCount == chunk.integrity.byteCount
        let sessionMatches = acknowledgment.sessionID == chunk.sessionID
        guard digestMatches && sizeMatches && sessionMatches else {
            entries[index].status = .failed
            entries[index].lastError = "ack-mismatch"
            persist()
            diagnostics.emit(.transfer, name: "ack-mismatch", severity: .error, payload: [
                "chunkID": chunk.id.uuidString,
                "expectedSHA": String(chunk.integrity.sha256Hex.prefix(16)),
                "ackSHA": String(acknowledgment.verifiedSHA256Hex.prefix(16)),
                "expectedBytes": "\(chunk.integrity.byteCount)",
                "ackBytes": "\(acknowledgment.storedByteCount)"
            ])
            return
        }
        removeChunkFile(chunk)
        entries.remove(at: index)
        persist()
        diagnostics.emit(.transfer, name: "chunk-acknowledged", payload: [
            "chunkID": chunk.id.uuidString,
            "seq": "\(chunk.integrity.sequenceNumber)",
            "pending": "\(entries.count)"
        ])
    }

    /// Explicit deletion — a propagated deletion intent or local purge. The
    /// file and queue row go away regardless of ack state.
    public func discardChunk(chunkID: UUID) async throws {
        guard let index = entries.firstIndex(where: { $0.chunk.id == chunkID }) else {
            throw RecorderError.notFound
        }
        let chunk = entries[index].chunk
        removeChunkFile(chunk)
        entries.remove(at: index)
        persist()
        diagnostics.emit(.transfer, name: "chunk-discarded", payload: [
            "chunkID": chunk.id.uuidString,
            "seq": "\(chunk.integrity.sequenceNumber)"
        ])
    }

    // MARK: - Pump & transport events

    private var pumpAgain = false

    /// Re-entrancy-safe drain: a pump request arriving mid-flight is
    /// coalesced and runs once more after the current pass finishes, so an
    /// enqueue landing during a send is never lost until the next event.
    private func pump() async {
        if pumping {
            pumpAgain = true
            return
        }
        pumping = true
        repeat {
            pumpAgain = false
            await drainOnce()
        } while pumpAgain
        pumping = false
    }

    /// A delivered transfer whose durable ack never arrived is re-queued
    /// after this window — resend is safe because the receive contract
    /// requires the phone to deduplicate on chunk id.
    static let ackTimeout: TimeInterval = 10 * 60

    /// Manifest↔outbox reconcile cadence while the process stays alive.
    /// `activate()` is the primary hook; this bounds how long a missed
    /// enqueue can strand during uninterrupted background capture.
    static let reconcileInterval: TimeInterval = 10 * 60
    private var lastManifestReconcileAt: Date = .distantPast

    private func drainOnce() async {
        var changed = false
        // Requeue stale awaiting-ack entries before picking what to send.
        let now = Date()
        if now.timeIntervalSince(lastManifestReconcileAt) > Self.reconcileInterval {
            reconcileManifestsWithOutbox()
        }
        for index in entries.indices {
            guard entries[index].status == .awaitingAcknowledgment,
                  let last = entries[index].lastAttemptAt,
                  now.timeIntervalSince(last) > Self.ackTimeout
            else { continue }
            entries[index].status = .queued
            entries[index].lastError = "ack-timeout"
            changed = true
            diagnostics.emit(.transfer, name: "ack-timeout-requeue", severity: .warning,
                             payload: ["chunkID": entries[index].chunk.id.uuidString])
        }
        // FIFO by capture order: oldest sequence first.
        let due = entries
            .filter { $0.status == .queued || ($0.status == .failed && $0.attemptCount < Self.maxAttempts) }
            .sorted { $0.chunk.integrity.sequenceNumber < $1.chunk.integrity.sequenceNumber }
        for entry in due {
            guard let index = entries.firstIndex(where: { $0.chunk.id == entry.chunk.id }) else {
                continue
            }
            let url = paths.url(for: entry.chunk)
            guard FileManager.default.fileExists(atPath: url.path) else {
                entries[index].status = .failed
                entries[index].lastError = "file-missing"
                changed = true
                diagnostics.emit(.transfer, name: "chunk-file-missing", severity: .error,
                                 payload: ["chunkID": entry.chunk.id.uuidString,
                                           "file": entry.chunk.fileName])
                continue
            }
            do {
                try await transport.send(fileAt: url, chunk: entry.chunk)
                entries[index].status = .inFlight
                entries[index].attemptCount += 1
                entries[index].lastAttemptAt = Date()
                entries[index].lastError = nil
            } catch {
                entries[index].lastError = "\(error)"
                // A dead transport fails the whole batch — stop rather than spin.
                diagnostics.emit(.transfer, name: "pump-send-failed", severity: .warning,
                                 payload: ["error": "\(error)"])
                changed = true
                break
            }
            changed = true
        }
        if changed { persist() }
    }

    /// Manifest↔outbox reconcile: a chunk persisted into the capture
    /// manifest but never enqueued — crash or persist failure inside the
    /// seal→enqueue window — has no outbox row and would strand forever.
    /// Any manifested chunk with no row whose file still exists is re-queued
    /// here; orphan cleanup keeps manifested files, so the file's presence
    /// is proof it was never retired. Idempotent: existing rows are skipped
    /// by chunk id, and an already-retired chunk (verified-ack deletion
    /// removes both row and file; explicit discard does the same) has no
    /// file and is left alone rather than surfaced as a false failure.
    private func reconcileManifestsWithOutbox() {
        lastManifestReconcileAt = Date()
        let sessionStore = CaptureSessionStore(paths: paths)
        let manifestsDir = paths.root
            .appendingPathComponent("manifests", isDirectory: true)
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: manifestsDir.path)) ?? []
        var tracked = Set(entries.map { $0.chunk.id })
        var recovered = 0
        for name in names where name.hasSuffix(".json") {
            guard let sessionID = UUID(uuidString: String(name.dropLast(".json".count)))
            else { continue }
            for chunk in sessionStore.loadManifest(sessionID: sessionID) {
                guard !tracked.contains(chunk.id) else { continue }
                guard FileManager.default
                    .fileExists(atPath: paths.url(for: chunk).path)
                else { continue }
                entries.append(OutboxEntry(
                    chunk: chunk,
                    status: .queued,
                    enqueuedAt: Date(),
                    attemptCount: 0,
                    lastAttemptAt: nil,
                    lastError: "manifest-reconcile"
                ))
                tracked.insert(chunk.id)
                recovered += 1
                diagnostics.emit(.transfer, name: "reconcile-recovered-chunk",
                                 severity: .warning,
                                 payload: ["chunkID": chunk.id.uuidString,
                                           "sessionID": chunk.sessionID.uuidString,
                                           "seq": "\(chunk.integrity.sequenceNumber)",
                                           "file": chunk.fileName])
            }
        }
        if recovered > 0 {
            persist()
            diagnostics.emit(.transfer, name: "manifest-reconcile",
                             payload: ["recovered": "\(recovered)",
                                       "entries": "\(entries.count)"])
        }
    }

    private var pumping = false

    private func handleTransportEvent(_ event: TransportEvent) async {
        switch event {
        case .activated:
            diagnostics.emit(.transfer, name: "transport-activated")
            await pump()
        case .peerReachable(let reachable):
            diagnostics.emit(.transfer, name: "peer-reachability",
                             payload: ["reachable": "\(reachable)"])
            if reachable { await pump() }
        case .fileFinished(let chunkID, let error):
            await fileFinished(chunkID: chunkID, error: error)
        case .acknowledgment(let ack):
            try? await apply(acknowledgment: ack)
        case .discardRequested(let chunkID):
            try? await discardChunk(chunkID: chunkID)
        }
    }

    /// `transferFile` finished: on success the chunk now waits for the durable
    /// ack; on failure it returns to `queued` for the next pump.
    private func fileFinished(chunkID: UUID, error: String?) async {
        guard let index = entries.firstIndex(where: { $0.chunk.id == chunkID }) else { return }
        if let error {
            entries[index].status = .queued
            entries[index].lastError = error
            diagnostics.emit(.transfer, name: "transfer-failed", severity: .warning,
                             payload: ["chunkID": chunkID.uuidString, "error": error])
        } else {
            entries[index].status = .awaitingAcknowledgment
            diagnostics.emit(.transfer, name: "transfer-delivered", payload: [
                "chunkID": chunkID.uuidString,
                "seq": "\(entries[index].chunk.integrity.sequenceNumber)"
            ])
        }
        persist()
    }

    private func removeChunkFile(_ chunk: AudioChunkMetadata) {
        let url = paths.url(for: chunk)
        try? FileManager.default.removeItem(at: url)
    }

    private func persist() {
        do {
            try store.save(entries)
        } catch {
            diagnostics.emit(.transfer, name: "outbox-persist-failed", severity: .error,
                             payload: ["error": "\(error)"])
        }
    }
}
