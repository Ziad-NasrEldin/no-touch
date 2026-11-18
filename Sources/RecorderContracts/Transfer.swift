import Foundation

public enum TransferStatus: String, Codable, Sendable {
    case queued
    case inFlight
    case awaitingAcknowledgment
    case acknowledged
    case failed
}

/// Sent by the phone only after the chunk bytes were moved into owned durable
/// storage and the digest verified. The watch keeps its copy until this arrives.
public struct TransferAcknowledgment: Codable, Sendable, Equatable, Hashable {
    public var chunkID: UUID
    public var sessionID: UUID
    public var status: TransferStatus
    public var acknowledgedAt: Date
    public var verifiedSHA256Hex: String
    public var storedByteCount: Int

    public init(
        chunkID: UUID,
        sessionID: UUID,
        status: TransferStatus = .acknowledged,
        acknowledgedAt: Date,
        verifiedSHA256Hex: String,
        storedByteCount: Int
    ) {
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.status = status
        self.acknowledgedAt = acknowledgedAt
        self.verifiedSHA256Hex = verifiedSHA256Hex
        self.storedByteCount = storedByteCount
    }
}
