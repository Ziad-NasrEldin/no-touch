import Foundation

/// C1 boundary: watch-side capture controls and session truth.
/// `stateUpdates` is the only authoritative state stream; `recording` is
/// emitted only while capture is actually active.
public protocol WatchCaptureServiceProtocol: Sendable {
    func startSession() async throws -> RecordingSession
    func pauseSession() async throws -> RecordingSession
    func resumeSession() async throws -> RecordingSession
    func stopSession() async throws -> RecordingSession
    func currentSession() async -> RecordingSession?
    func finalizedChunks(sessionID: UUID) async -> [AudioChunkMetadata]
    func stateUpdates() -> AsyncStream<RecordingSession>
}

/// Durable watch-side outbox. Chunks stay queued until the phone's
/// acknowledgment arrives; discarding requires the ack or an explicit deletion.
public protocol WatchTransferServiceProtocol: Sendable {
    func enqueueForTransfer(_ chunk: AudioChunkMetadata) async throws
    func chunksAwaitingAcknowledgment(sessionID: UUID) async -> [AudioChunkMetadata]
    func markInFlight(chunkID: UUID) async throws
    func apply(acknowledgment: TransferAcknowledgment) async throws
    func discardChunk(chunkID: UUID) async throws
}

/// S1 boundary: phone-side receive. Implementations must move the temporary
/// file into owned storage and verify the digest before acknowledging.
public protocol PhoneReceiveServiceProtocol: Sendable {
    func storeReceivedChunk(data: Data, metadata: AudioChunkMetadata) async throws -> TransferAcknowledgment
    func receivedChunks(sessionID: UUID) async -> [AudioChunkMetadata]
}

/// S1 boundary: archive persistence, job queue, overrides, and deletion.
public protocol ConversationArchiveStoreProtocol: Sendable {
    func upsertTranscriptSegments(_ segments: [TranscriptSegment]) async throws
    func upsertConversationGroup(_ group: ConversationGroup) async throws
    func upsertGeneratedMetadata(_ metadata: GeneratedConversationMetadata) async throws
    func recordUserOverride(_ override: UserOverrideRecord) async throws
    func applyDeletionIntent(_ intent: DeletionIntent) async throws
    func conversationGroups(sessionID: UUID) async throws -> [ConversationGroup]
    func transcriptSegments(conversationID: UUID) async throws -> [TranscriptSegment]
    func enqueueAnalysisJob(_ job: AnalysisJob) async throws
    func nextAnalysisJob(kind: AnalysisJobKind?) async throws -> AnalysisJob?
    func updateAnalysisJob(_ job: AnalysisJob) async throws
    func audioAvailability(conversationID: UUID) async throws -> AudioAvailabilityState
}

/// A1 boundary: on-device speech transcription (never translation, never
/// cloud). Output preserves Arabic/English spans with source timing.
public protocol SpeechTranscriptionAdapterProtocol: Sendable {
    func readiness() async -> ModelReadinessState
    func transcribe(audioFileURL: URL, chunk: AudioChunkMetadata) async throws -> [TranscriptSegment]
}

/// A1 boundary: on-device text intelligence — grouping, titles, summaries,
/// categories, decisions, action items. Every generated claim carries sources.
public protocol TextIntelligenceAdapterProtocol: Sendable {
    func readiness() async -> ModelReadinessState
    func proposeConversationGroups(sessionID: UUID, segments: [TranscriptSegment]) async throws -> [ConversationGroup]
    func generateMetadata(conversationID: UUID, segments: [TranscriptSegment]) async throws -> GeneratedConversationMetadata
}
