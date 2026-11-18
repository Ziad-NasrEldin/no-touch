import Foundation
import RecorderContracts

/// Phase 0 placeholder for S1. In-memory archive + job queue exercising the
/// real contract so I1/U1 can bind; S1 replaces internals with durable storage.
/// Deletion intents suppress deleted content from reads immediately.
public actor PlaceholderArchiveStore: ConversationArchiveStoreProtocol {
    private var segments: [UUID: TranscriptSegment] = [:]
    private var groups: [UUID: ConversationGroup] = [:]
    private var metadata: [UUID: GeneratedConversationMetadata] = [:]
    private var overrides: [UUID: [UserOverrideRecord]] = [:]
    private var deletions: Set<UUID> = []
    private var jobs: [UUID: AnalysisJob] = [:]

    public init() {}

    public func upsertTranscriptSegments(_ newSegments: [TranscriptSegment]) async throws {
        for segment in newSegments where !deletions.contains(segment.id) {
            segments[segment.id] = segment
        }
    }

    public func upsertConversationGroup(_ group: ConversationGroup) async throws {
        guard !deletions.contains(group.id) else { return }
        groups[group.id] = group
    }

    public func upsertGeneratedMetadata(_ newMetadata: GeneratedConversationMetadata) async throws {
        guard !deletions.contains(newMetadata.conversationID) else { return }
        metadata[newMetadata.conversationID] = newMetadata
    }

    public func recordUserOverride(_ override: UserOverrideRecord) async throws {
        overrides[override.conversationID, default: []].append(override)
    }

    public func applyDeletionIntent(_ intent: DeletionIntent) async throws {
        deletions.insert(intent.targetID)
        switch intent.target {
        case .conversation:
            groups.removeValue(forKey: intent.targetID)
            metadata.removeValue(forKey: intent.targetID)
            for id in jobs.keys where jobs[id]?.conversationID == intent.targetID {
                jobs[id]?.state = .cancelled
            }
        case .chunk:
            for id in segments.keys where segments[id]?.chunkID == intent.targetID {
                segments.removeValue(forKey: id)
            }
            for id in jobs.keys where jobs[id]?.chunkID == intent.targetID {
                jobs[id]?.state = .cancelled
            }
        case .session:
            for id in groups.keys where groups[id]?.sessionID == intent.targetID {
                groups.removeValue(forKey: id)
                metadata.removeValue(forKey: id)
            }
            for id in segments.keys where segments[id]?.sessionID == intent.targetID {
                segments.removeValue(forKey: id)
            }
        }
    }

    public func conversationGroups(sessionID: UUID) async throws -> [ConversationGroup] {
        groups.values
            .filter { $0.sessionID == sessionID }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    public func transcriptSegments(conversationID: UUID) async throws -> [TranscriptSegment] {
        guard let group = groups[conversationID] else { return [] }
        return group.segmentIDs.compactMap { segments[$0] }
            .sorted { ($0.wallStartTime ?? .distantPast) < ($1.wallStartTime ?? .distantPast) }
    }

    public func enqueueAnalysisJob(_ job: AnalysisJob) async throws {
        jobs[job.id] = job
    }

    public func nextAnalysisJob(kind: AnalysisJobKind?) async throws -> AnalysisJob? {
        jobs.values
            .filter { $0.state == .queued && (kind == nil || $0.kind == kind) }
            .sorted { $0.createdAt < $1.createdAt }
            .first
    }

    public func updateAnalysisJob(_ job: AnalysisJob) async throws {
        jobs[job.id] = job
    }

    public func audioAvailability(conversationID: UUID) async throws -> AudioAvailabilityState {
        // Phase 0 retains no audio files; S1 reports real states from storage.
        .pending
    }
}
