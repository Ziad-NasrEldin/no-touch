import Foundation
import RecorderContracts

/// Phase 0 placeholder for A1. No model is installed or inferred here; callers
/// can bind against the real contract and observe honest readiness.
public struct PlaceholderSpeechTranscriptionAdapter: SpeechTranscriptionAdapterProtocol {
    public init() {}

    public func readiness() async -> ModelReadinessState {
        .notInstalled
    }

    public func transcribe(audioFileURL: URL, chunk: AudioChunkMetadata) async throws -> [TranscriptSegment] {
        throw RecorderError.modelNotReady
    }
}

/// Phase 0 placeholder for A1's text-intelligence lane (grouping, titles,
/// summaries, categories, decisions, action items).
public struct PlaceholderTextIntelligenceAdapter: TextIntelligenceAdapterProtocol {
    public init() {}

    public func readiness() async -> ModelReadinessState {
        .notInstalled
    }

    public func proposeConversationGroups(
        sessionID: UUID,
        segments: [TranscriptSegment]
    ) async throws -> [ConversationGroup] {
        throw RecorderError.modelNotReady
    }

    public func generateMetadata(
        conversationID: UUID,
        segments: [TranscriptSegment]
    ) async throws -> GeneratedConversationMetadata {
        throw RecorderError.modelNotReady
    }
}
