import Foundation
import RecorderContracts
import PhoneAI
import PhoneStorage

/// Phase 0 seam for I1: wires receive → archive job enqueue behind one
/// coordinator so the lanes' real implementations can drop in without the
/// app layer changing. Not a processing pipeline yet.
public actor SessionCoordinator {
    private let receiver: any PhoneReceiveServiceProtocol
    private let archive: any ConversationArchiveStoreProtocol
    private let transcriber: any SpeechTranscriptionAdapterProtocol
    private let intelligence: any TextIntelligenceAdapterProtocol

    public init(
        receiver: any PhoneReceiveServiceProtocol,
        archive: any ConversationArchiveStoreProtocol,
        transcriber: any SpeechTranscriptionAdapterProtocol,
        intelligence: any TextIntelligenceAdapterProtocol
    ) {
        self.receiver = receiver
        self.archive = archive
        self.transcriber = transcriber
        self.intelligence = intelligence
    }

    /// Receives a verified chunk and queues a bounded transcription job.
    public func ingestChunk(
        data: Data,
        metadata: AudioChunkMetadata
    ) async throws -> TransferAcknowledgment {
        let ack = try await receiver.storeReceivedChunk(data: data, metadata: metadata)
        try await archive.enqueueAnalysisJob(
            AnalysisJob(kind: .transcription, chunkID: metadata.id)
        )
        return ack
    }

    public func transcriptionReadiness() async -> ModelReadinessState {
        await transcriber.readiness()
    }

    public func intelligenceReadiness() async -> ModelReadinessState {
        await intelligence.readiness()
    }

    public func archiveStore() -> any ConversationArchiveStoreProtocol {
        archive
    }
}
