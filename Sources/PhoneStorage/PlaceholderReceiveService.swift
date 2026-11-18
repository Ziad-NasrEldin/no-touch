import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import RecorderContracts

/// Phase 0 placeholder for S1. Verifies chunk digests (so the ack contract is
/// honest) but stores received bytes in memory rather than durable storage;
/// S1 adds the receive directory, deduplication, and retry persistence.
public actor PlaceholderReceiveService: PhoneReceiveServiceProtocol {
    private var stored: [UUID: (metadata: AudioChunkMetadata, bytes: Int)] = [:]

    public init() {}

    public func storeReceivedChunk(
        data: Data,
        metadata: AudioChunkMetadata
    ) async throws -> TransferAcknowledgment {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == metadata.integrity.sha256Hex.lowercased(),
              data.count == metadata.integrity.byteCount else {
            throw RecorderError.integrityMismatch
        }
        // Idempotent: duplicate delivery overwrites the same slot.
        stored[metadata.id] = (metadata, data.count)
        return TransferAcknowledgment(
            chunkID: metadata.id,
            sessionID: metadata.sessionID,
            acknowledgedAt: Date(),
            verifiedSHA256Hex: digest,
            storedByteCount: data.count
        )
    }

    public func receivedChunks(sessionID: UUID) async -> [AudioChunkMetadata] {
        stored.values
            .map(\.metadata)
            .filter { $0.sessionID == sessionID }
            .sorted { $0.integrity.sequenceNumber < $1.integrity.sequenceNumber }
    }
}
