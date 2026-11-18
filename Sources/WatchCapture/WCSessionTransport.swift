import Foundation
import RecorderContracts

#if canImport(WatchConnectivity)

import WatchConnectivity

/// `WCSession`-backed transport. `transferFile` queues deliveries while the
/// phone is unreachable; the durable ack arrives back on any inbound channel
/// and is decoded into `TransportEvent`s for the outbox to consume.
///
/// Wire contract (documented for S1/I1):
/// - Outbound: `transferFile` with metadata
///   `["chunkID": String, "sessionID": String, "sequenceNumber": Int,
///     "fileName": String, "chunk": Data(JSON AudioChunkMetadata)]`.
/// - Inbound: see `InboundCommandDecoder` — ack or discard, any channel.
final class WCSessionTransport: NSObject, WatchChunkTransport, WCSessionDelegate, @unchecked Sendable {
    private let session: WCSession
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]

    init(session: WCSession = .default) {
        self.session = session
        super.init()
    }

    var events: AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    private func yield(_ event: TransportEvent) {
        lock.lock()
        let sinks = Array(continuations.values)
        lock.unlock()
        for sink in sinks { sink.yield(event) }
    }

    func activate() async throws {
        guard WCSession.isSupported() else { throw TransportError.unsupported }
        session.delegate = self
        session.activate()
    }

    func send(fileAt url: URL, chunk: AudioChunkMetadata) async throws {
        guard session.activationState == .activated else { throw TransportError.notActivated }
        let chunkJSON = try? JSONEncoder().encode(chunk)
        var metadata: [String: Any] = [
            "chunkID": chunk.id.uuidString,
            "sessionID": chunk.sessionID.uuidString,
            "sequenceNumber": chunk.integrity.sequenceNumber,
            "fileName": chunk.fileName
        ]
        metadata["chunk"] = chunkJSON ?? Data()
        // `transferFile` returns nonnull on watchOS and queues the transfer
        // even while the phone is unreachable; errors surface via
        // `session(_:didFinish:error:)` and feed `fileFinished`.
        _ = session.transferFile(url, metadata: metadata)
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated, error == nil {
            yield(.activated)
            yield(.peerReachable(session.isReachable))
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        yield(.peerReachable(session.isReachable))
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let rawID = fileTransfer.file.metadata?["chunkID"] as? String
        guard let id = rawID.flatMap(UUID.init(uuidString:)) else { return }
        yield(.fileFinished(chunkID: id, error: error.map { "\($0)" }))
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleInbound(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleInbound(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleInbound(message)
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handleInbound(messageData)
    }

    func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        handleInbound(messageData)
        replyHandler(Data())
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleInbound(applicationContext)
    }

    private func handleInbound(_ object: Any) {
        switch InboundCommandDecoder.decode(object) {
        case .acknowledgment(let ack):
            yield(.acknowledgment(ack))
        case .discard(let chunkID):
            yield(.discardRequested(chunkID: chunkID))
        case nil:
            break
        }
    }
}

#else

/// Platforms without WatchConnectivity (the `swift build` host build). The
/// outbox still persists and reports honestly; sends always fail visibly.
final class UnavailableChunkTransport: WatchChunkTransport {
    var events: AsyncStream<TransportEvent> {
        AsyncStream { $0.finish() }
    }

    func activate() async throws { throw TransportError.unsupported }
    func send(fileAt url: URL, chunk: AudioChunkMetadata) async throws {
        throw TransportError.unsupported
    }
}

#endif
