import Foundation
import RecorderContracts

/// Internal seam between the durable outbox (`WatchTransferService`) and the
/// wire transport. Everything above this seam is plain Codable types and
/// persisted state, so S1/I1 can integrate the phone side without touching
/// queue logic, and a manual/debug transport can be substituted in tests of
/// the manual path.
protocol WatchChunkTransport: Sendable {
    /// Transport events; always available, replaying nothing.
    var events: AsyncStream<TransportEvent> { get }
    /// Prepares the transport (e.g. activates `WCSession`). Throws when the
    /// platform has no transport — the outbox stays durable regardless.
    func activate() async throws
    /// Offers one chunk file for delivery. Implementations may accept work
    /// while the peer is unreachable (WatchConnectivity queues transfers) but
    /// must throw if the transport itself is not running.
    func send(fileAt url: URL, chunk: AudioChunkMetadata) async throws
}

enum TransportEvent: Sendable {
    /// Transport is live; pending work can be pushed.
    case activated
    /// Peer reachability changed (nil = unknown/not applicable).
    case peerReachable(Bool)
    /// A file transfer finished on the wire. `error == nil` means delivered to
    /// the peer's inbox — durable acknowledgment still follows separately.
    case fileFinished(chunkID: UUID, error: String?)
    /// Decoded durable acknowledgment from the phone.
    case acknowledgment(TransferAcknowledgment)
    /// Explicit deletion request propagated from the phone.
    case discardRequested(chunkID: UUID)
}

/// Errors the transport layer reports; recorded verbatim in outbox
/// `lastError`/diagnostics, never crossing the contract boundary as types.
enum TransportError: Error, Sendable {
    case notActivated
    case unsupported
    case sendFailed
}

// MARK: - Inbound wire decoding

/// Decoded payload accepted from the phone in any inbound channel.
enum InboundCommand: Sendable {
    case acknowledgment(TransferAcknowledgment)
    case discard(chunkID: UUID)
}

/// Liberal decoding of inbound phone messages. Accepted shapes (documented
/// for S1/I1):
/// - Dict `["type": "ack", "payload": Data]` where payload is JSON
///   `TransferAcknowledgment` (also `"ack"`/`"acknowledgment"` keys).
/// - Dict `["type": "discard", "chunkID": "<uuid>"]`.
/// - Dict carrying inline ack fields (`chunkID`, `sessionID`,
///   `verifiedSHA256Hex`, `storedByteCount`, optional `acknowledgedAt`).
/// - Raw `Data` containing JSON `TransferAcknowledgment`.
enum InboundCommandDecoder {
    static func decode(_ object: Any?) -> InboundCommand? {
        switch object {
        case let data as Data:
            return decodeAckData(data).map { .acknowledgment($0) }
        case let dict as [String: Any]:
            return decodeDictionary(dict)
        default:
            return nil
        }
    }

    private static func decodeDictionary(_ dict: [String: Any]) -> InboundCommand? {
        if let type = dict["type"] as? String {
            switch type {
            case "discard":
                if let raw = dict["chunkID"] as? String, let id = UUID(uuidString: raw) {
                    return .discard(chunkID: id)
                }
                return nil
            case "ack", "acknowledgment":
                return decodeAckFields(dict).map { .acknowledgment($0) }
            default:
                break
            }
        }
        // Envelope-less dictionaries that carry a full ack are still honored.
        return decodeAckFields(dict).map { .acknowledgment($0) }
    }

    private static func decodeAckFields(_ dict: [String: Any]) -> TransferAcknowledgment? {
        for key in ["payload", "ack", "acknowledgment"] {
            if let data = dict[key] as? Data, let ack = decodeAckData(data) {
                return ack
            }
        }
        guard
            let chunkID = (dict["chunkID"] as? String).flatMap(UUID.init(uuidString:)),
            let sessionID = (dict["sessionID"] as? String).flatMap(UUID.init(uuidString:)),
            let sha = dict["verifiedSHA256Hex"] as? String,
            let bytes = (dict["storedByteCount"] as? NSNumber)?.intValue
                ?? (dict["storedByteCount"] as? String).flatMap(Int.init)
        else { return nil }
        let date = decodeDate(dict["acknowledgedAt"]) ?? Date()
        return TransferAcknowledgment(
            chunkID: chunkID,
            sessionID: sessionID,
            status: .acknowledged,
            acknowledgedAt: date,
            verifiedSHA256Hex: sha,
            storedByteCount: bytes
        )
    }

    private static func decodeDate(_ value: Any?) -> Date? {
        switch value {
        case let date as Date:
            return date
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: string)
        default:
            return nil
        }
    }

    private static func decodeAckData(_ data: Data) -> TransferAcknowledgment? {
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let ack = try? iso.decode(TransferAcknowledgment.self, from: data) {
            return ack
        }
        return try? JSONDecoder().decode(TransferAcknowledgment.self, from: data)
    }
}
