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

/// I1 (Phase 2): promoted store APIs beyond the frozen receive/analyze
/// boundary — adopted from S1's contract request so app/integration code
/// binds a protocol, not `SQLiteArchiveStore` concretely. Everything here is
/// additive over `ConversationArchiveStoreProtocol`; semantics unchanged.
public protocol ExtendedArchiveStoreProtocol: ConversationArchiveStoreProtocol {
    /// Session-truth mirror (fed by the watch→phone session channel).
    func upsertSession(_ session: RecordingSession) async throws
    func session(id: UUID) async throws -> RecordingSession?
    func sessions() async throws -> [RecordingSession]
    /// Override surface: reads resolve generated output through user edits.
    func userOverrides(conversationID: UUID) async throws -> [UserOverrideRecord]
    func hasUserOverride(conversationID: UUID, field: UserOverrideRecord.Field) async throws -> Bool
    func generatedMetadata(conversationID: UUID) async throws -> GeneratedConversationMetadata?
    func effectiveMetadata(conversationID: UUID) async throws -> GeneratedConversationMetadata?
    /// Job inspection (queued/failed/cancelled states for resume + status UI).
    func analysisJobs(state: AnalysisJobState?) async throws -> [AnalysisJob]
    /// Playable file for a stored chunk; nil when expired/deleted/missing.
    func audioFileURL(chunkID: UUID) async throws -> URL?
    /// Local ar+en search foundation.
    func searchTranscripts(query: String, limit: Int) async throws -> [TranscriptSearchHit]
    /// Raw-audio retention sweep; returns how many chunk files expired.
    func enforceRetention(_ policy: RetentionPolicy, now: Date) async throws -> Int
    /// Deletion propagation to the watch outbox.
    func unpropagatedDeletionIntents() async throws -> [DeletionIntent]
    func markDeletionIntentsPropagated(_ ids: [UUID]) async throws
    /// Structured non-content evidence export (Gate A).
    func diagnosticsReport(deviceModel: String, osVersion: String, limit: Int) async throws -> DiagnosticsReport

    // MARK: - I1 integration reads (added with the promotion)

    /// All live transcript segments of a session, ordered by chunk sequence
    /// then media time — the input regrouping needs across chunk boundaries.
    func transcriptSegments(sessionID: UUID) async throws -> [TranscriptSegment]
    /// Registry lookup for a received chunk (nil when never stored).
    func chunkMetadata(id: UUID) async throws -> AudioChunkMetadata?
    /// Session ids that currently hold `stored` chunk rows — drives the
    /// missed-enqueue reconciliation without needing mirrored session rows.
    func sessionIDsWithStoredChunks() async throws -> [UUID]
    /// Session ids holding segments no group currently claims — drives
    /// regroup convergence after crashes or deletion reshuffles.
    func sessionIDsWithUngroupedSegments() async throws -> [UUID]
    /// Regroup bookkeeping (NOT user deletion): removes a group + its
    /// membership + generated metadata + pending jobs without tombstoning,
    /// so a reshuffled proposal can reuse the span legitimately.
    func disbandConversationGroup(conversationID: UUID) async throws
}

/// I1 (Phase 2): formalizes the file-delivery ingest seam S1 asked about.
/// `PhoneReceiveService` already implements it; transports (`WCSession`
/// file callbacks or alternates) can bind this instead of the concrete type.
public protocol PhoneFileIngestProtocol: PhoneReceiveServiceProtocol {
    /// Consumes an already-on-disk delivery: tombstone check → dedup →
    /// streaming verify → atomic move → registry → ack.
    func ingestReceivedFile(at url: URL, metadata: AudioChunkMetadata) async throws -> TransferAcknowledgment
}
