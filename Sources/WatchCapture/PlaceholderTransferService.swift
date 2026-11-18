import Foundation
import RecorderContracts

/// Phase 0 placeholder for the watch-side durable outbox consumed by S1's
/// contract. In-memory only; C1/S1 add persisted queue + WatchConnectivity.
public actor PlaceholderTransferService: WatchTransferServiceProtocol {
    private var queue: [UUID: AudioChunkMetadata] = [:]
    private var inFlight: Set<UUID> = []

    public init() {}

    public func enqueueForTransfer(_ chunk: AudioChunkMetadata) async throws {
        queue[chunk.id] = chunk
    }

    public func chunksAwaitingAcknowledgment(sessionID: UUID) async -> [AudioChunkMetadata] {
        queue.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.integrity.sequenceNumber < $1.integrity.sequenceNumber }
    }

    public func markInFlight(chunkID: UUID) async throws {
        guard queue[chunkID] != nil else { throw RecorderError.notFound }
        inFlight.insert(chunkID)
    }

    /// Durable phone ack retires the chunk from the outbox. The watch copy is
    /// deleted only after this point (or explicit user deletion).
    public func apply(acknowledgment: TransferAcknowledgment) async throws {
        guard acknowledgment.status == .acknowledged else { return }
        queue.removeValue(forKey: acknowledgment.chunkID)
        inFlight.remove(acknowledgment.chunkID)
    }

    public func discardChunk(chunkID: UUID) async throws {
        queue.removeValue(forKey: chunkID)
        inFlight.remove(chunkID)
    }
}
