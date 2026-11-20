import Foundation
import SQLite3
import RecorderContracts

/// Chunk registry row — the durable dedup index entry. `state` is one of
/// `stored` | `expired` | `deleted`; rows are never removed so receive-side
/// dedup and audit survive file expiration.
struct ChunkRecord: Sendable {
    var id: UUID
    var sessionID: UUID
    var fileName: String
    var relativePath: String
    var sha256: String
    var byteCount: Int
    var sequenceNumber: Int
    var metadata: AudioChunkMetadata
    var receivedAt: Date
    var state: String

    static let stored = "stored"
    static let expired = "expired"
    static let deleted = "deleted"
}

/// Anything that can durably record structured diagnostics. The store is the
/// default sink; other lanes may substitute their own (or a silent one).
public protocol DiagnosticsSink: Sendable {
    func record(_ event: DiagnosticsEvent) async
}

/// Durable archive: sessions, received chunks + dedup index, transcript
/// segments, conversation groups, generated metadata, user overrides,
/// analysis jobs, deletion tombstones, local search index, diagnostics.
///
/// Boundary rules enforced here (spec: Deletion and retention, Local privacy):
/// - Every upsert checks `deletion_intents` first — tombstoned content is
///   never resurrected by delayed transfers, retries, or late AI output.
/// - `generated_metadata` stores model output verbatim; reads resolve through
///   `overrides` so user edits always win (`effectiveMetadata`,
///   `hasUserOverride`).
/// - Conversation deletion invalidates queued jobs and cascades to orphaned
///   chunk files; implicit chunk tombstones propagate to the Watch so remote
///   copies are removed too.
///
/// Concurrency: all database calls are synchronous and run under this actor's
/// isolation; actor methods never suspend between them, so multi-statement
/// transactions are atomic.
public actor SQLiteArchiveStore: ExtendedArchiveStoreProtocol, DiagnosticsSink {
    private let database: ArchiveDatabase
    private let layout: ArchiveFileLayout
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private var prepared = false
    private var diagnosticsSinceTrim = 0
    private static let diagnosticsCap = 5000
    private static let diagnosticsTrimInterval = 200

    /// Non-throwing init so the F0 app shell (`PlaceholderArchiveStore()`)
    /// keeps working; the database opens lazily on first use, or eagerly via
    /// `prepare()` so integration can surface storage failures at app launch.
    public init(directory: URL? = nil, excludeDerivedDataFromBackup: Bool = true) {
        let resolved = directory.map {
            ArchiveFileLayout(root: $0, excludeDerivedDataFromBackup: excludeDerivedDataFromBackup)
        } ?? .default()
        self.layout = resolved
        self.database = ArchiveDatabase(fileURL: resolved.databaseFile)
    }

    /// Root directory of the archive on disk (diagnostics/integration only).
    public nonisolated var archiveDirectory: URL { layout.root }

    /// Creates directories, applies protection/backup attributes, opens the
    /// database, and runs crash repair. Safe to call repeatedly.
    public func prepare() async throws {
        try openIfNeeded()
    }

    private func ensureOpen() throws {
        try openIfNeeded()
    }

    private func openIfNeeded() throws {
        guard !prepared else { return }
        try layout.prepare()
        try database.open()
        prepared = true
        try repairAfterRestart()
    }

    // MARK: - Crash/restart repair

    /// After a kill mid-job, `.running` rows are lies — nothing is running.
    /// They return to `.queued` with attempt history intact so retry
    /// accounting stays honest.
    private func repairAfterRestart() throws {
        let recovered = try database.scalarInt(
            "SELECT COUNT(*) FROM jobs WHERE state = 'running'"
        )
        if recovered > 0 {
            try database.execute("UPDATE jobs SET state = 'queued' WHERE state = 'running'")
            emitDiag(
                name: "storage.jobs_recovered_to_queue",
                severity: .warning,
                payload: ["count": "\(recovered)"]
            )
        }
    }

    // MARK: - Tombstones

    /// True when a deletion intent covers `targetID` at `target` granularity.
    func isTombstoned(target: DeletionIntent.Target, targetID: UUID) throws -> Bool {
        try database.scalarInt(
            "SELECT COUNT(*) FROM deletion_intents WHERE target = ? AND target_id = ?",
            [.text(target.rawValue), .uuid(targetID)]
        ) > 0
    }

    /// Chunk-level guard used by the receive path: covers direct chunk
    /// tombstones and whole-session tombstones.
    func chunkDeliveryIsTombstoned(chunkID: UUID, sessionID: UUID) throws -> Bool {
        try database.scalarInt(
            """
            SELECT COUNT(*) FROM deletion_intents
            WHERE (target = 'chunk' AND target_id = ?)
               OR (target = 'session' AND target_id = ?)
            """,
            [.uuid(chunkID), .uuid(sessionID)]
        ) > 0
    }

    private func insertTombstone(_ intent: DeletionIntent) throws {
        let existing = try database.scalarInt(
            "SELECT COUNT(*) FROM deletion_intents WHERE target = ? AND target_id = ?",
            [.text(intent.target.rawValue), .uuid(intent.targetID)]
        )
        if existing == 0 {
            try database.execute(
                """
                INSERT INTO deletion_intents (id, target, target_id, created_at, propagated_to_watch)
                VALUES (?, ?, ?, ?, ?)
                """,
                [.uuid(intent.id), .text(intent.target.rawValue), .uuid(intent.targetID),
                 .date(intent.createdAt), .bool(intent.propagatedToWatch)]
            )
        }
    }

    /// Creates a chunk tombstone implicitly (cascade from conversation/session
    /// deletion) so the Watch also drops its copy once intents propagate.
    private func tombstoneChunkCascade(chunkID: UUID, now: Date) throws {
        try insertTombstone(DeletionIntent(target: .chunk, targetID: chunkID, createdAt: now))
    }

    // MARK: - ConversationArchiveStoreProtocol

    public func upsertTranscriptSegments(_ segments: [TranscriptSegment]) async throws {
        try ensureOpen()
        guard !segments.isEmpty else { return }
        try database.inTransaction {
            for segment in segments {
                let suppressed = try database.scalarInt(
                    """
                    SELECT COUNT(*) FROM deletion_intents
                    WHERE (target = 'chunk' AND target_id = ?)
                       OR (target = 'session' AND target_id = ?)
                    """,
                    [.uuid(segment.chunkID), .uuid(segment.sessionID)]
                ) > 0
                if suppressed {
                    emitDiag(
                        name: "storage.upsert_suppressed_by_tombstone",
                        payload: ["entity": "segment", "id": segment.id.uuidString]
                    )
                    continue
                }
                let normalized = TranscriptNormalizer.normalize(segment.text)
                try database.execute(
                    """
                    INSERT INTO segments (id, chunk_id, session_id, start_time, end_time,
                                          wall_start_time, text, normalized_text,
                                          language_spans_json, confidence, speaker_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        chunk_id=excluded.chunk_id, session_id=excluded.session_id,
                        start_time=excluded.start_time, end_time=excluded.end_time,
                        wall_start_time=excluded.wall_start_time, text=excluded.text,
                        normalized_text=excluded.normalized_text,
                        language_spans_json=excluded.language_spans_json,
                        confidence=excluded.confidence,
                        speaker_id=excluded.speaker_id
                    """,
                    [.uuid(segment.id), .uuid(segment.chunkID), .uuid(segment.sessionID),
                     .real(segment.startTime), .real(segment.endTime),
                     .date(segment.wallStartTime), .text(segment.text), .text(normalized),
                     .text(try encode(segment.languageSpans)),
                     segment.confidence.map { .real($0) } ?? .null,
                     segment.speakerID.map { .int(Int64($0)) } ?? .null]
                )
                try reindex(segment: segment)
            }
        }
    }

    public func upsertConversationGroup(_ group: ConversationGroup) async throws {
        try ensureOpen()
        if try isTombstoned(target: .conversation, targetID: group.id)
            || isTombstoned(target: .session, targetID: group.sessionID) {
            emitDiag(
                name: "storage.upsert_suppressed_by_tombstone",
                payload: ["entity": "group", "id": group.id.uuidString]
            )
            return
        }
        try database.inTransaction {
            try database.execute(
                """
                INSERT INTO groups (id, session_id, is_provisional, started_at, ended_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    session_id=excluded.session_id, is_provisional=excluded.is_provisional,
                    started_at=excluded.started_at, ended_at=excluded.ended_at
                """,
                [.uuid(group.id), .uuid(group.sessionID), .bool(group.isProvisional),
                 .date(group.startedAt), .date(group.endedAt)]
            )
            try database.execute(
                "DELETE FROM group_membership WHERE conversation_id = ?",
                [.uuid(group.id)]
            )
            for (position, segmentID) in group.segmentIDs.enumerated() {
                try database.execute(
                    "INSERT OR REPLACE INTO group_membership (conversation_id, segment_id, position) VALUES (?, ?, ?)",
                    [.uuid(group.id), .uuid(segmentID), .int(Int64(position))]
                )
            }
        }
    }

    public func upsertGeneratedMetadata(_ metadata: GeneratedConversationMetadata) async throws {
        try ensureOpen()
        if try isTombstoned(target: .conversation, targetID: metadata.conversationID) {
            emitDiag(
                name: "storage.upsert_suppressed_by_tombstone",
                payload: ["entity": "metadata", "id": metadata.conversationID.uuidString]
            )
            return
        }
        try database.execute(
            """
            INSERT INTO generated_metadata
                (conversation_id, title, summary, suggested_category,
                 decisions_json, action_items_json, sources_json, model_version, generated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(conversation_id) DO UPDATE SET
                title=excluded.title, summary=excluded.summary,
                suggested_category=excluded.suggested_category,
                decisions_json=excluded.decisions_json,
                action_items_json=excluded.action_items_json,
                sources_json=excluded.sources_json,
                model_version=excluded.model_version, generated_at=excluded.generated_at
            """,
            [.uuid(metadata.conversationID),
             metadata.title.map { .text($0) } ?? .null,
             metadata.summary.map { .text($0) } ?? .null,
             metadata.suggestedCategory.map { .text($0) } ?? .null,
             .text(try encode(metadata.decisions)),
             .text(try encode(metadata.actionItems)),
             .text(try encode(metadata.sources)),
             .text(metadata.modelVersion), .date(metadata.generatedAt)]
        )
    }

    public func recordUserOverride(_ override: UserOverrideRecord) async throws {
        try ensureOpen()
        if try isTombstoned(target: .conversation, targetID: override.conversationID) {
            emitDiag(
                name: "storage.upsert_suppressed_by_tombstone",
                payload: ["entity": "override", "id": override.conversationID.uuidString]
            )
            return
        }
        try database.execute(
            "INSERT INTO overrides (id, conversation_id, field, value, created_at) VALUES (?, ?, ?, ?, ?)",
            [.uuid(override.id), .uuid(override.conversationID), .text(override.field.rawValue),
             .text(override.value), .date(override.createdAt)]
        )
        emitDiag(
            name: "storage.user_override_recorded",
            payload: ["conversation_id": override.conversationID.uuidString,
                      "field": override.field.rawValue]
        )
    }

    public func applyDeletionIntent(_ intent: DeletionIntent) async throws {
        try ensureOpen()
        try database.inTransaction {
            try insertTombstone(intent)
            switch intent.target {
            case .conversation:
                try deleteConversationCascade(conversationID: intent.targetID, now: intent.createdAt)
            case .chunk:
                try deleteChunkCascade(chunkID: intent.targetID, now: intent.createdAt)
            case .session:
                try deleteSessionCascade(sessionID: intent.targetID, now: intent.createdAt)
            }
        }
        emitDiag(
            name: "storage.deletion_applied",
            payload: ["target": intent.target.rawValue, "target_id": intent.targetID.uuidString]
        )
    }

    public func conversationGroups(sessionID: UUID) async throws -> [ConversationGroup] {
        try ensureOpen()
        let groups = try database.query(
            """
            SELECT g.id, g.session_id, g.is_provisional, g.started_at, g.ended_at
            FROM groups g
            WHERE g.session_id = ?
              AND NOT EXISTS (SELECT 1 FROM deletion_intents d
                              WHERE d.target = 'conversation' AND d.target_id = g.id)
            ORDER BY COALESCE(g.started_at, 0)
            """,
            [.uuid(sessionID)]
        ) { statement in
            (
                id: ArchiveDatabase.uuid(statement, 0),
                sessionID: ArchiveDatabase.uuid(statement, 1),
                isProvisional: sqlite3_column_int(statement, 2) != 0,
                startedAt: ArchiveDatabase.optionalDate(statement, 3),
                endedAt: ArchiveDatabase.optionalDate(statement, 4)
            )
        }
        return try groups.map { row in
            ConversationGroup(
                id: row.id,
                sessionID: row.sessionID,
                segmentIDs: try segmentIDs(conversationID: row.id),
                isProvisional: row.isProvisional,
                startedAt: row.startedAt,
                endedAt: row.endedAt
            )
        }
    }

    public func transcriptSegments(conversationID: UUID) async throws -> [TranscriptSegment] {
        try ensureOpen()
        return try database.query(
            """
            SELECT s.id, s.chunk_id, s.session_id, s.start_time, s.end_time,
                   s.wall_start_time, s.text, s.language_spans_json, s.confidence, s.speaker_id
            FROM group_membership m JOIN segments s ON s.id = m.segment_id
            WHERE m.conversation_id = ?
            ORDER BY m.position
            """,
            [.uuid(conversationID)],
            row: mapSegment
        )
    }

    public func enqueueAnalysisJob(_ job: AnalysisJob) async throws {
        try ensureOpen()
        if let chunkID = job.chunkID, try isTombstoned(target: .chunk, targetID: chunkID) {
            emitDiag(name: "storage.job_suppressed_by_tombstone",
                     payload: ["job_id": job.id.uuidString, "kind": job.kind.rawValue])
            return
        }
        if let conversationID = job.conversationID,
           try isTombstoned(target: .conversation, targetID: conversationID) {
            emitDiag(name: "storage.job_suppressed_by_tombstone",
                     payload: ["job_id": job.id.uuidString, "kind": job.kind.rawValue])
            return
        }
        // Dedup identical pending work so re-enqueues after relaunch can't
        // duplicate results (spec: resumed without duplicating results).
        let duplicate = try database.scalarInt(
            """
            SELECT COUNT(*) FROM jobs
            WHERE kind = ? AND state IN ('queued','running')
              AND COALESCE(chunk_id,'') = COALESCE(?, '')
              AND COALESCE(conversation_id,'') = COALESCE(?, '')
            """,
            [.text(job.kind.rawValue), .uuid(job.chunkID), .uuid(job.conversationID)]
        ) > 0
        if duplicate {
            emitDiag(name: "storage.job_dedup_hit",
                     payload: ["kind": job.kind.rawValue,
                               "chunk_id": job.chunkID?.uuidString ?? "",
                               "conversation_id": job.conversationID?.uuidString ?? ""])
            return
        }
        try database.execute(Self.jobInsertSQL, Self.jobParams(job))
    }

    public func nextAnalysisJob(kind: AnalysisJobKind?) async throws -> AnalysisJob? {
        try ensureOpen()
        let sql = """
            SELECT id, kind, state, chunk_id, conversation_id, attempt_count,
                   last_error, model_version, created_at, updated_at
            FROM jobs WHERE state = 'queued'
            """
        if let kind {
            return try database.querySingle(
                sql + " AND kind = ? ORDER BY created_at LIMIT 1",
                [.text(kind.rawValue)],
                row: Self.mapJob
            )
        }
        return try database.querySingle(sql + " ORDER BY created_at LIMIT 1", row: Self.mapJob)
    }

    public func updateAnalysisJob(_ job: AnalysisJob) async throws {
        try ensureOpen()
        try database.execute(Self.jobInsertSQL, Self.jobParams(job))
    }

    /// Rollup across every chunk the conversation's segments reference:
    /// `.available` = all playable, `.pending` = nothing playable yet and
    /// nothing lost, `.expired` = losses are retention-only, `.deleted` =
    /// the conversation is tombstoned or any referenced audio was explicitly
    /// deleted. Per-span availability is a documented contract gap (I1).
    public func audioAvailability(conversationID: UUID) async throws -> AudioAvailabilityState {
        try ensureOpen()
        if try isTombstoned(target: .conversation, targetID: conversationID) {
            return .deleted
        }
        let chunkIDs = try database.query(
            """
            SELECT DISTINCT s.chunk_id FROM group_membership m
            JOIN segments s ON s.id = m.segment_id WHERE m.conversation_id = ?
            """,
            [.uuid(conversationID)]
        ) { ArchiveDatabase.uuid($0, 0) }
        guard !chunkIDs.isEmpty else { return .pending }

        var playable = 0, expired = 0, deleted = 0, missing = 0
        for chunkID in chunkIDs {
            if try isTombstoned(target: .chunk, targetID: chunkID) {
                deleted += 1
                continue
            }
            guard let record = try chunkRecord(id: chunkID) else {
                missing += 1
                continue
            }
            switch record.state {
            case ChunkRecord.expired:
                expired += 1
            case ChunkRecord.deleted:
                deleted += 1
            default:
                if fileExists(relativePath: record.relativePath) {
                    playable += 1
                } else {
                    missing += 1
                }
            }
        }
        let total = chunkIDs.count
        if deleted > 0 { return .deleted }
        if playable == total { return .available }
        if playable == 0 && expired > 0 && missing == 0 { return .expired }
        if playable == 0 && missing == total { return .pending }
        return .expired
    }

    // MARK: - Sessions (additive API beyond the frozen protocol)

    public func upsertSession(_ session: RecordingSession) async throws {
        try ensureOpen()
        if try isTombstoned(target: .session, targetID: session.id) {
            emitDiag(name: "storage.upsert_suppressed_by_tombstone",
                     payload: ["entity": "session", "id": session.id.uuidString])
            return
        }
        try database.execute(
            """
            INSERT INTO sessions (id, state, failure_reason, started_at, stopped_at,
                                  last_confirmed_capture_at, interruptions_json, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                state=excluded.state, failure_reason=excluded.failure_reason,
                started_at=excluded.started_at, stopped_at=excluded.stopped_at,
                last_confirmed_capture_at=excluded.last_confirmed_capture_at,
                interruptions_json=excluded.interruptions_json, updated_at=excluded.updated_at
            """,
            [.uuid(session.id), .text(session.state.rawValue),
             session.failureReason.map { .text($0.rawValue) } ?? .null,
             .date(session.startedAt), .date(session.stoppedAt),
             .date(session.lastConfirmedCaptureAt),
             .text(try encode(session.interruptionIntervals)),
             .date(Date())]
        )
    }

    public func session(id: UUID) async throws -> RecordingSession? {
        try ensureOpen()
        return try database.querySingle(
            """
            SELECT state, failure_reason, started_at, stopped_at,
                   last_confirmed_capture_at, interruptions_json
            FROM sessions WHERE id = ?
            """,
            [.uuid(id)]
        ) { statement in
            RecordingSession(
                id: id,
                state: SessionState(rawValue: ArchiveDatabase.text(statement, 0)) ?? .idle,
                failureReason: ArchiveDatabase.optionalText(statement, 1)
                    .flatMap(FailureReason.init(rawValue:)),
                startedAt: ArchiveDatabase.optionalDate(statement, 2),
                stoppedAt: ArchiveDatabase.optionalDate(statement, 3),
                lastConfirmedCaptureAt: ArchiveDatabase.optionalDate(statement, 4),
                interruptionIntervals: (try? decode(
                    [InterruptionInterval].self,
                    from: ArchiveDatabase.text(statement, 5)
                )) ?? []
            )
        }
    }

    public func sessions() async throws -> [RecordingSession] {
        try ensureOpen()
        return try database.query(
            """
            SELECT id, state, failure_reason, started_at, stopped_at,
                   last_confirmed_capture_at, interruptions_json
            FROM sessions ORDER BY COALESCE(started_at, 0)
            """
        ) { statement in
            RecordingSession(
                id: ArchiveDatabase.uuid(statement, 0),
                state: SessionState(rawValue: ArchiveDatabase.text(statement, 1)) ?? .idle,
                failureReason: ArchiveDatabase.optionalText(statement, 2)
                    .flatMap(FailureReason.init(rawValue:)),
                startedAt: ArchiveDatabase.optionalDate(statement, 3),
                stoppedAt: ArchiveDatabase.optionalDate(statement, 4),
                lastConfirmedCaptureAt: ArchiveDatabase.optionalDate(statement, 5),
                interruptionIntervals: (try? decode(
                    [InterruptionInterval].self,
                    from: ArchiveDatabase.text(statement, 6)
                )) ?? []
            )
        }
    }

    // MARK: - User overrides (explicit override check for A1/I1)

    public func userOverrides(conversationID: UUID) async throws -> [UserOverrideRecord] {
        try ensureOpen()
        return try database.query(
            "SELECT id, field, value, created_at FROM overrides WHERE conversation_id = ? ORDER BY created_at",
            [.uuid(conversationID)]
        ) { statement in
            UserOverrideRecord(
                id: ArchiveDatabase.uuid(statement, 0),
                conversationID: conversationID,
                field: UserOverrideRecord.Field(rawValue: ArchiveDatabase.text(statement, 1)) ?? .title,
                value: ArchiveDatabase.text(statement, 2),
                createdAt: ArchiveDatabase.date(statement, 3)
            )
        }
    }

    /// The override check A1/I1 must consult before writing regenerated
    /// output: any record for (conversation, field) means the user owns it.
    public func hasUserOverride(conversationID: UUID, field: UserOverrideRecord.Field) async throws -> Bool {
        try ensureOpen()
        return try database.scalarInt(
            "SELECT COUNT(*) FROM overrides WHERE conversation_id = ? AND field = ?",
            [.uuid(conversationID), .text(field.rawValue)]
        ) > 0
    }

    /// Generated row as stored (model output, versioned).
    public func generatedMetadata(conversationID: UUID) async throws -> GeneratedConversationMetadata? {
        try ensureOpen()
        return try database.querySingle(
            """
            SELECT title, summary, suggested_category, decisions_json,
                   action_items_json, sources_json, model_version, generated_at
            FROM generated_metadata WHERE conversation_id = ?
            """,
            [.uuid(conversationID)]
        ) { statement in
            GeneratedConversationMetadata(
                conversationID: conversationID,
                title: ArchiveDatabase.optionalText(statement, 0),
                summary: ArchiveDatabase.optionalText(statement, 1),
                suggestedCategory: ArchiveDatabase.optionalText(statement, 2),
                decisions: (try? decode([DecisionItem].self,
                                             from: ArchiveDatabase.text(statement, 3))) ?? [],
                actionItems: (try? decode([ActionItem].self,
                                               from: ArchiveDatabase.text(statement, 4))) ?? [],
                sources: (try? decode([SourcePassageReference].self,
                                           from: ArchiveDatabase.text(statement, 5))) ?? [],
                modelVersion: ArchiveDatabase.text(statement, 6),
                generatedAt: ArchiveDatabase.date(statement, 7)
            )
        }
    }

    /// Effective view: generated output with user-overridden fields swapped in.
    /// This is what the UI should render and what reprocessing must compare
    /// against — overridden fields never change here.
    public func effectiveMetadata(conversationID: UUID) async throws -> GeneratedConversationMetadata? {
        var metadata = try await generatedMetadata(conversationID: conversationID)
        let overrides = try await userOverrides(conversationID: conversationID)
        guard !overrides.isEmpty else { return metadata }

        var latest: [UserOverrideRecord.Field: UserOverrideRecord] = [:]
        for record in overrides { latest[record.field] = record }

        if metadata == nil, !latest.isEmpty {
            metadata = GeneratedConversationMetadata(
                conversationID: conversationID, modelVersion: "user-override"
            )
        }
        if let title = latest[.title]?.value { metadata?.title = title }
        if let category = latest[.category]?.value { metadata?.suggestedCategory = category }
        if let summary = latest[.summary]?.value { metadata?.summary = summary }
        return metadata
    }

    // MARK: - Analysis jobs (inspection helpers beyond the protocol)

    public func analysisJobs(state: AnalysisJobState? = nil) async throws -> [AnalysisJob] {
        try ensureOpen()
        let base = """
            SELECT id, kind, state, chunk_id, conversation_id, attempt_count,
                   last_error, model_version, created_at, updated_at FROM jobs
            """
        if let state {
            return try database.query(
                base + " WHERE state = ? ORDER BY created_at",
                [.text(state.rawValue)],
                row: Self.mapJob
            )
        }
        return try database.query(base + " ORDER BY created_at", row: Self.mapJob)
    }

    // MARK: - Local search foundation (ar + en)

    /// AND-semantics token match with prefix behavior: every normalized query
    /// token must match an indexed term exactly or as a prefix. Returns one
    /// hit per (segment, conversation) pair — nil conversation for ungrouped
    /// segments — newest first.
    public func searchTranscripts(query: String, limit: Int = 50) async throws -> [TranscriptSearchHit] {
        try ensureOpen()
        let tokens = TranscriptNormalizer.tokens(from: query)
        guard !tokens.isEmpty else { return [] }

        let intersections = tokens.map { _ in
            "SELECT segment_id FROM search_terms WHERE term >= ? AND term <= ?"
        }.joined(separator: " INTERSECT ")
        var params = tokens.flatMap { token -> [SQLiteValue] in
            let bounds = TranscriptNormalizer.prefixBounds(token)
            return [.text(bounds.lower), .text(bounds.upper)]
        }
        params.append(.int(Int64(limit)))

        let sql = """
            SELECT s.id, s.chunk_id, s.session_id, s.start_time, s.end_time,
                   s.wall_start_time, s.text, s.language_spans_json, s.confidence, s.speaker_id,
                   m.conversation_id
            FROM segments s
            LEFT JOIN group_membership m ON m.segment_id = s.id
            WHERE s.id IN (\(intersections))
              AND NOT EXISTS (SELECT 1 FROM deletion_intents d
                              WHERE d.target = 'chunk' AND d.target_id = s.chunk_id)
            ORDER BY COALESCE(s.wall_start_time, 0) DESC, s.start_time DESC
            LIMIT ?
            """
        let rows = try database.query(sql, params) { statement in
            (
                segment: mapSegment(statement),
                conversationID: ArchiveDatabase.optionalUUID(statement, 10)
            )
        }
        var hits: [TranscriptSearchHit] = []
        var seen: Set<String> = []
        for row in rows {
            let key = "\(row.segment.id.uuidString)|\(row.conversationID?.uuidString ?? "-")"
            if seen.insert(key).inserted {
                hits.append(TranscriptSearchHit(
                    segment: row.segment,
                    conversationID: row.conversationID,
                    matchedTerms: tokens
                ))
            }
        }
        emitDiag(
            name: "storage.search_executed",
            payload: ["token_count": "\(tokens.count)", "hits": "\(hits.count)"]
        )
        return hits
    }

    // MARK: - Retention

    /// Applies raw-audio retention: files are removed (rows and transcripts
    /// kept, marked `expired` so playback state stays explainable per spec).
    /// - `keepAudioDays`: chunks received earlier than now−days expire.
    /// - `deleteAudioAfterTranscription`: chunks with a succeeded
    ///   transcription job expire immediately.
    /// Both conditions set ⇒ chunk must satisfy both before expiring.
    public func enforceRetention(_ policy: RetentionPolicy, now: Date = Date()) async throws -> Int {
        try ensureOpen()
        var candidates = try chunkRecords(state: ChunkRecord.stored)

        if policy.deleteAudioAfterTranscription {
            let transcribed = try database.query(
                """
                SELECT DISTINCT chunk_id FROM jobs
                WHERE kind = 'transcription' AND state = 'succeeded' AND chunk_id IS NOT NULL
                """
            ) { ArchiveDatabase.uuid($0, 0) }
            let transcribedSet = Set(transcribed)
            candidates = candidates.filter { transcribedSet.contains($0.id) }
        }
        if let days = policy.keepAudioDays {
            let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86400)
            candidates = candidates.filter { $0.receivedAt < cutoff }
        }

        var expiredCount = 0
        for record in candidates {
            try removeChunkFile(relativePath: record.relativePath)
            try database.execute(
                "UPDATE chunks SET state = ? WHERE id = ?",
                [.text(ChunkRecord.expired), .uuid(record.id)]
            )
            expiredCount += 1
        }
        if expiredCount > 0 {
            emitDiag(name: "storage.retention_expired",
                     payload: ["chunks": "\(expiredCount)"])
        }
        return expiredCount
    }

    // MARK: - Deletion propagation (to Watch)

    public func unpropagatedDeletionIntents() async throws -> [DeletionIntent] {
        try ensureOpen()
        return try database.query(
            """
            SELECT id, target, target_id, created_at FROM deletion_intents
            WHERE propagated_to_watch = 0 ORDER BY created_at
            """
        ) { statement in
            DeletionIntent(
                id: ArchiveDatabase.uuid(statement, 0),
                target: DeletionIntent.Target(rawValue: ArchiveDatabase.text(statement, 1)) ?? .chunk,
                targetID: ArchiveDatabase.uuid(statement, 2),
                createdAt: ArchiveDatabase.date(statement, 3),
                propagatedToWatch: false
            )
        }
    }

    public func markDeletionIntentsPropagated(_ ids: [UUID]) async throws {
        try ensureOpen()
        for id in ids {
            try database.execute(
                "UPDATE deletion_intents SET propagated_to_watch = 1 WHERE id = ?",
                [.uuid(id)]
            )
        }
    }

    // MARK: - DiagnosticsSink

    public func record(_ event: DiagnosticsEvent) async {
        try? ensureOpen()
        try? database.execute(
            "INSERT INTO diagnostics (id, ts, subsystem, severity, name, payload_json) VALUES (?, ?, ?, ?, ?, ?)",
            [.uuid(event.id), .date(event.timestamp), .text(event.subsystem.rawValue),
             .text(event.severity.rawValue), .text(event.name),
             .text((try? encode(event.payload)) ?? "{}")]
        )
        diagnosticsSinceTrim += 1
        if diagnosticsSinceTrim >= Self.diagnosticsTrimInterval {
            diagnosticsSinceTrim = 0
            try? database.execute(
                """
                DELETE FROM diagnostics WHERE seq NOT IN (
                    SELECT seq FROM diagnostics ORDER BY seq DESC LIMIT \(Self.diagnosticsCap))
                """
            )
        }
    }

    public func diagnosticsReport(
        deviceModel: String,
        osVersion: String,
        limit: Int = 5000
    ) async throws -> DiagnosticsReport {
        try ensureOpen()
        let events = try database.query(
            """
            SELECT id, ts, subsystem, severity, name, payload_json
            FROM diagnostics ORDER BY seq DESC LIMIT ?
            """,
            [.int(Int64(limit))]
        ) { statement in
            DiagnosticsEvent(
                id: ArchiveDatabase.uuid(statement, 0),
                timestamp: ArchiveDatabase.date(statement, 1),
                subsystem: DiagnosticsSubsystem(rawValue: ArchiveDatabase.text(statement, 2)) ?? .storage,
                severity: DiagnosticsSeverity(rawValue: ArchiveDatabase.text(statement, 3)) ?? .info,
                name: ArchiveDatabase.text(statement, 4),
                payload: (try? decode([String: String].self,
                                           from: ArchiveDatabase.text(statement, 5))) ?? [:]
            )
        }
        return DiagnosticsReport(
            deviceModel: deviceModel,
            osVersion: osVersion,
            events: events.reversed()
        )
    }

    // MARK: - Chunk registry (internal — consumed by PhoneReceiveService)

    func chunkRecord(id: UUID) throws -> ChunkRecord? {
        try ensureOpen()
        return try database.querySingle(
            """
            SELECT session_id, file_name, relative_path, sha256, byte_count,
                   sequence_number, metadata_json, received_at, state
            FROM chunks WHERE id = ?
            """,
            [.uuid(id)]
        ) { statement in
            ChunkRecord(
                id: id,
                sessionID: ArchiveDatabase.uuid(statement, 0),
                fileName: ArchiveDatabase.text(statement, 1),
                relativePath: ArchiveDatabase.text(statement, 2),
                sha256: ArchiveDatabase.text(statement, 3),
                byteCount: Int(sqlite3_column_int64(statement, 4)),
                sequenceNumber: Int(sqlite3_column_int64(statement, 5)),
                metadata: (try? decode(AudioChunkMetadata.self,
                                            from: ArchiveDatabase.text(statement, 6)))
                    ?? AudioChunkMetadata(
                        id: id,
                        sessionID: ArchiveDatabase.uuid(statement, 0),
                        fileName: ArchiveDatabase.text(statement, 1),
                        format: AudioChunkFormat(container: "", codec: "", sampleRate: 0),
                        integrity: ChunkIntegrity(
                            sha256Hex: ArchiveDatabase.text(statement, 3),
                            byteCount: Int(sqlite3_column_int64(statement, 4)),
                            duration: 0, sequenceNumber: 0,
                            monotonicStartSeconds: 0, monotonicEndSeconds: 0,
                            wallStartedAt: .distantPast, wallEndedAt: .distantPast
                        )
                    ),
                receivedAt: ArchiveDatabase.date(statement, 7),
                state: ArchiveDatabase.text(statement, 8)
            )
        }
    }

    /// Registers a chunk whose file already sits durably at `relativePath`.
    /// Called ONLY after verify + atomic move — never before.
    func registerStoredChunk(
        metadata: AudioChunkMetadata,
        relativePath: String,
        receivedAt: Date
    ) throws {
        try ensureOpen()
        try database.execute(
            """
            INSERT INTO chunks (id, session_id, file_name, relative_path, sha256,
                                byte_count, sequence_number, metadata_json, received_at, state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'stored')
            ON CONFLICT(id) DO UPDATE SET
                session_id=excluded.session_id, file_name=excluded.file_name,
                relative_path=excluded.relative_path, sha256=excluded.sha256,
                byte_count=excluded.byte_count, sequence_number=excluded.sequence_number,
                metadata_json=excluded.metadata_json, received_at=excluded.received_at,
                state='stored'
            """,
            [.uuid(metadata.id), .uuid(metadata.sessionID), .text(metadata.fileName),
             .text(relativePath), .text(metadata.integrity.sha256Hex.lowercased()),
             .int(Int64(metadata.integrity.byteCount)), .int(Int64(metadata.integrity.sequenceNumber)),
             .text(try encode(metadata)), .date(receivedAt)]
        )
    }

    func receivedChunkMetadata(sessionID: UUID) throws -> [AudioChunkMetadata] {
        try ensureOpen()
        return try database.query(
            """
            SELECT metadata_json FROM chunks
            WHERE session_id = ? AND state != 'deleted'
            ORDER BY sequence_number
            """,
            [.uuid(sessionID)]
        ) { statement in
            try? decode(AudioChunkMetadata.self,
                             from: ArchiveDatabase.text(statement, 0))
        }.compactMap { $0 }
    }

    func chunkRecords(state: String? = nil) throws -> [ChunkRecord] {
        try ensureOpen()
        let sql = """
            SELECT id, session_id, file_name, relative_path, sha256, byte_count,
                   sequence_number, metadata_json, received_at, state FROM chunks
            """
        if let state {
            return try database.query(sql + " WHERE state = ?", [.text(state)],
                                      row: mapChunkRecord)
        }
        return try database.query(sql, row: mapChunkRecord)
    }

    /// On-disk path for playback/transcription. Nil unless the chunk is in
    /// `stored` state AND the file is actually present.
    public func audioFileURL(chunkID: UUID) async throws -> URL? {
        guard let record = try chunkRecord(id: chunkID), record.state == ChunkRecord.stored else {
            return nil
        }
        let url = layout.root.appendingPathComponent(record.relativePath)
        return fileExists(relativePath: record.relativePath) ? url : nil
    }

    func fileExists(relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: layout.root.appendingPathComponent(relativePath).path
        )
    }

    func removeChunkFile(relativePath: String) throws {
        let url = layout.root.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Path of the durable destination for `metadata`, relative to the root.
    func relativePath(for metadata: AudioChunkMetadata) -> String {
        layout.relativePath(for: layout.durableFileURL(for: metadata))
    }

    /// Nonisolated: `layout` is immutable, so the file layout can be read
    /// from WCSession delegate callbacks (synchronous) safely.
    nonisolated var storageLayout: ArchiveFileLayout { layout }

    // MARK: - Deletion cascades

    /// Deletes a conversation's own rows plus its orphaned chunk files.
    /// Chunk files shared with live conversations are kept (spec option:
    /// "leaving other transcripts intact"); span-level audio redaction inside
    /// a still-shared file is a documented gap for I1.
    private func deleteConversationCascade(conversationID: UUID, now: Date) throws {
        let segmentIDs = try database.query(
            "SELECT segment_id FROM group_membership WHERE conversation_id = ?",
            [.uuid(conversationID)]
        ) { ArchiveDatabase.uuid($0, 0) }
        let affectedChunkIDs = try database.query(
            """
            SELECT DISTINCT chunk_id FROM segments WHERE id IN
            (SELECT segment_id FROM group_membership WHERE conversation_id = ?)
            """,
            [.uuid(conversationID)]
        ) { ArchiveDatabase.uuid($0, 0) }

        for segmentID in segmentIDs {
            try deleteSegmentRows(segmentID: segmentID)
        }
        try database.execute(
            "DELETE FROM group_membership WHERE conversation_id = ?", [.uuid(conversationID)]
        )
        try database.execute("DELETE FROM groups WHERE id = ?", [.uuid(conversationID)])
        try database.execute(
            "DELETE FROM generated_metadata WHERE conversation_id = ?", [.uuid(conversationID)]
        )
        try database.execute(
            """
            UPDATE jobs SET state = 'cancelled', updated_at = ?
            WHERE conversation_id = ? AND state IN ('queued','running')
            """,
            [.date(now), .uuid(conversationID)]
        )
        // Orphaned chunks (no remaining live segments): tombstone + drop file
        // so delayed redelivery cannot resurrect them and the Watch can drop
        // its copy once the intent propagates.
        for chunkID in affectedChunkIDs {
            let remaining = try database.scalarInt(
                "SELECT COUNT(*) FROM segments WHERE chunk_id = ?", [.uuid(chunkID)]
            )
            if remaining == 0 {
                try tombstoneChunkCascade(chunkID: chunkID, now: now)
                try deleteChunkRowsAndFile(chunkID: chunkID)
                try database.execute(
                    """
                    UPDATE jobs SET state = 'cancelled', updated_at = ?
                    WHERE chunk_id = ? AND state IN ('queued','running')
                    """,
                    [.date(now), .uuid(chunkID)]
                )
            }
        }
    }

    private func deleteChunkCascade(chunkID: UUID, now: Date) throws {
        let segmentIDs = try database.query(
            "SELECT id FROM segments WHERE chunk_id = ?", [.uuid(chunkID)]
        ) { ArchiveDatabase.uuid($0, 0) }
        for segmentID in segmentIDs {
            try deleteSegmentRows(segmentID: segmentID)
        }
        try deleteChunkRowsAndFile(chunkID: chunkID)
        try database.execute(
            """
            UPDATE jobs SET state = 'cancelled', updated_at = ?
            WHERE chunk_id = ? AND state IN ('queued','running')
            """,
            [.date(now), .uuid(chunkID)]
        )
        try pruneEmptyGroups(now: now)
    }

    private func deleteSessionCascade(sessionID: UUID, now: Date) throws {
        let chunkIDs = try database.query(
            "SELECT id FROM chunks WHERE session_id = ?", [.uuid(sessionID)]
        ) { ArchiveDatabase.uuid($0, 0) }
        for chunkID in chunkIDs {
            try tombstoneChunkCascade(chunkID: chunkID, now: now)
            try deleteChunkCascade(chunkID: chunkID, now: now)
        }
        let groupIDs = try database.query(
            "SELECT id FROM groups WHERE session_id = ?", [.uuid(sessionID)]
        ) { ArchiveDatabase.uuid($0, 0) }
        for groupID in groupIDs {
            try insertTombstone(DeletionIntent(
                target: .conversation, targetID: groupID, createdAt: now
            ))
            try database.execute(
                "DELETE FROM group_membership WHERE conversation_id = ?", [.uuid(groupID)]
            )
            try database.execute("DELETE FROM groups WHERE id = ?", [.uuid(groupID)])
            try database.execute(
                "DELETE FROM generated_metadata WHERE conversation_id = ?", [.uuid(groupID)]
            )
            try database.execute(
                """
                UPDATE jobs SET state = 'cancelled', updated_at = ?
                WHERE conversation_id = ? AND state IN ('queued','running')
                """,
                [.date(now), .uuid(groupID)]
            )
        }
        try database.execute(
            "DELETE FROM segments WHERE session_id = ?", [.uuid(sessionID)]
        )
        try database.execute("DELETE FROM sessions WHERE id = ?", [.uuid(sessionID)])
    }

    private func deleteSegmentRows(segmentID: UUID) throws {
        try database.execute("DELETE FROM segments WHERE id = ?", [.uuid(segmentID)])
        try database.execute("DELETE FROM search_terms WHERE segment_id = ?", [.uuid(segmentID)])
        try database.execute("DELETE FROM group_membership WHERE segment_id = ?", [.uuid(segmentID)])
    }

    private func deleteChunkRowsAndFile(chunkID: UUID) throws {
        if let record = try chunkRecord(id: chunkID) {
            try removeChunkFile(relativePath: record.relativePath)
            try database.execute(
                "UPDATE chunks SET state = ? WHERE id = ?",
                [.text(ChunkRecord.deleted), .uuid(chunkID)]
            )
        }
    }

    /// Groups with zero remaining members are removed (not tombstoned — a
    /// future regroup may legitimately reuse the span through new proposals).
    private func pruneEmptyGroups(now: Date) throws {
        let empty = try database.query(
            """
            SELECT id FROM groups g WHERE NOT EXISTS
            (SELECT 1 FROM group_membership m WHERE m.conversation_id = g.id)
            """
        ) { ArchiveDatabase.uuid($0, 0) }
        for groupID in empty {
            try database.execute("DELETE FROM groups WHERE id = ?", [.uuid(groupID)])
            try database.execute(
                "DELETE FROM generated_metadata WHERE conversation_id = ?", [.uuid(groupID)]
            )
            try database.execute(
                """
                UPDATE jobs SET state = 'cancelled', updated_at = ?
                WHERE conversation_id = ? AND state IN ('queued','running')
                """,
                [.date(now), .uuid(groupID)]
            )
        }
    }

    // MARK: - Integration reads (I1 — ExtendedArchiveStoreProtocol)

    /// All live segments of a session across chunk boundaries, ordered by the
    /// chunk registry's sequence number then media time — the regrouper's
    /// input. Segments on tombstoned chunks are excluded even though the
    /// deletion cascade already removes them (defense in depth).
    public func transcriptSegments(sessionID: UUID) async throws -> [TranscriptSegment] {
        try ensureOpen()
        return try database.query(
            """
            SELECT s.id, s.chunk_id, s.session_id, s.start_time, s.end_time,
                   s.wall_start_time, s.text, s.language_spans_json, s.confidence, s.speaker_id
            FROM segments s JOIN chunks c ON c.id = s.chunk_id
            WHERE s.session_id = ?
              AND NOT EXISTS (SELECT 1 FROM deletion_intents d
                              WHERE d.target = 'chunk' AND d.target_id = s.chunk_id)
            ORDER BY c.sequence_number, s.start_time
            """,
            [.uuid(sessionID)],
            row: mapSegment
        )
    }

    /// Registry metadata for a received chunk (nil when never stored or the
    /// row fell to `deleted` without metadata — callers treat nil alike).
    public func chunkMetadata(id: UUID) async throws -> AudioChunkMetadata? {
        try ensureOpen()
        return try chunkRecord(id: id)?.metadata
    }

    /// Sessions currently holding `stored` chunk rows — the reconciliation
    /// set for missed enqueue passes; independent of the sessions mirror.
    public func sessionIDsWithStoredChunks() async throws -> [UUID] {
        try ensureOpen()
        return try database.query(
            "SELECT DISTINCT session_id FROM chunks WHERE state = ?",
            [.text(ChunkRecord.stored)]
        ) { ArchiveDatabase.uuid($0, 0) }
    }

    /// Sessions holding segments no group claims — drives regroup convergence
    /// after crashes between the transcription drain and the regroup step.
    public func sessionIDsWithUngroupedSegments() async throws -> [UUID] {
        try ensureOpen()
        return try database.query(
            """
            SELECT DISTINCT s.session_id FROM segments s
            WHERE NOT EXISTS (SELECT 1 FROM group_membership m
                              WHERE m.segment_id = s.id)
              AND NOT EXISTS (SELECT 1 FROM deletion_intents d
                              WHERE d.target = 'chunk' AND d.target_id = s.chunk_id)
              AND NOT EXISTS (SELECT 1 FROM deletion_intents d
                              WHERE d.target = 'session' AND d.target_id = s.session_id)
            """
        ) { ArchiveDatabase.uuid($0, 0) }
    }

    /// True when ANY job row exists for (kind, chunk) regardless of state —
    /// the ingest hook's once-per-chunk guard so dedup re-stores or expiry
    /// redeliveries can never enqueue a second transcription for one chunk.
    public func hasAnalysisJob(kind: AnalysisJobKind, chunkID: UUID) async throws -> Bool {
        try ensureOpen()
        return try database.scalarInt(
            "SELECT COUNT(*) FROM jobs WHERE kind = ? AND chunk_id = ?",
            [.text(kind.rawValue), .uuid(chunkID)]
        ) > 0
    }

    /// Regroup bookkeeping only — removes a group's structure without
    /// tombstoning, so reshuffled spans may legitimately be regrouped under
    /// another conversation. User overrides for the disbanded id remain as
    /// inert rows (keeping them is the conservative choice: a regroup is not
    /// a user deletion and must never erase user data).
    public func disbandConversationGroup(conversationID: UUID) async throws {
        try ensureOpen()
        let now = Date()
        try database.inTransaction {
            try database.execute(
                "DELETE FROM group_membership WHERE conversation_id = ?", [.uuid(conversationID)]
            )
            try database.execute("DELETE FROM groups WHERE id = ?", [.uuid(conversationID)])
            try database.execute(
                "DELETE FROM generated_metadata WHERE conversation_id = ?", [.uuid(conversationID)]
            )
            try database.execute(
                """
                UPDATE jobs SET state = 'cancelled', updated_at = ?
                WHERE conversation_id = ? AND state IN ('queued','running')
                """,
                [.date(now), .uuid(conversationID)]
            )
        }
        emitDiag(
            name: "storage.group_disbanded",
            payload: ["conversation_id": conversationID.uuidString]
        )
    }

    // MARK: - Search index maintenance

    private func reindex(segment: TranscriptSegment) throws {
        try database.execute(
            "DELETE FROM search_terms WHERE segment_id = ?", [.uuid(segment.id)]
        )
        var seen: Set<String> = []
        for token in TranscriptNormalizer.tokens(from: segment.text) where seen.insert(token).inserted {
            try database.execute(
                "INSERT INTO search_terms (term, segment_id) VALUES (?, ?)",
                [.text(token), .uuid(segment.id)]
            )
        }
    }

    private func segmentIDs(conversationID: UUID) throws -> [UUID] {
        try database.query(
            "SELECT segment_id FROM group_membership WHERE conversation_id = ? ORDER BY position",
            [.uuid(conversationID)]
        ) { ArchiveDatabase.uuid($0, 0) }
    }

    // MARK: - Diagnostics helper

    private func emitDiag(
        name: String,
        severity: DiagnosticsSeverity = .info,
        payload: [String: String]
    ) {
        try? database.execute(
            "INSERT INTO diagnostics (id, ts, subsystem, severity, name, payload_json) VALUES (?, ?, ?, ?, ?, ?)",
            [.uuid(UUID()), .date(Date()), .text(DiagnosticsSubsystem.storage.rawValue),
             .text(severity.rawValue), .text(name),
             .text((try? encode(payload)) ?? "{}")]
        )
    }

    // MARK: - Row mappers & coders

    private static let jobInsertSQL = """
        INSERT INTO jobs (id, kind, state, chunk_id, conversation_id, attempt_count,
                          last_error, model_version, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind=excluded.kind, state=excluded.state, chunk_id=excluded.chunk_id,
            conversation_id=excluded.conversation_id, attempt_count=excluded.attempt_count,
            last_error=excluded.last_error, model_version=excluded.model_version,
            created_at=excluded.created_at, updated_at=excluded.updated_at
        """

    private func mapSegment(_ statement: OpaquePointer) -> TranscriptSegment {
        TranscriptSegment(
            id: ArchiveDatabase.uuid(statement, 0),
            chunkID: ArchiveDatabase.uuid(statement, 1),
            sessionID: ArchiveDatabase.uuid(statement, 2),
            startTime: sqlite3_column_double(statement, 3),
            endTime: sqlite3_column_double(statement, 4),
            wallStartTime: ArchiveDatabase.optionalDate(statement, 5),
            text: ArchiveDatabase.text(statement, 6),
            languageSpans: (try? decode([LanguageSpan].self,
                                        from: ArchiveDatabase.text(statement, 7))) ?? [],
            confidence: sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 8),
            speakerID: sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, 9))
        )
    }

    private static func mapJob(_ statement: OpaquePointer) -> AnalysisJob {
        AnalysisJob(
            id: ArchiveDatabase.uuid(statement, 0),
            kind: AnalysisJobKind(rawValue: ArchiveDatabase.text(statement, 1)) ?? .transcription,
            state: AnalysisJobState(rawValue: ArchiveDatabase.text(statement, 2)) ?? .queued,
            chunkID: ArchiveDatabase.optionalUUID(statement, 3),
            conversationID: ArchiveDatabase.optionalUUID(statement, 4),
            attemptCount: Int(sqlite3_column_int64(statement, 5)),
            lastError: ArchiveDatabase.optionalText(statement, 6),
            modelVersion: ArchiveDatabase.optionalText(statement, 7),
            createdAt: ArchiveDatabase.date(statement, 8),
            updatedAt: ArchiveDatabase.date(statement, 9)
        )
    }

    private static func jobParams(_ job: AnalysisJob) -> [SQLiteValue] {
        [.uuid(job.id), .text(job.kind.rawValue), .text(job.state.rawValue),
         .uuid(job.chunkID), .uuid(job.conversationID), .int(Int64(job.attemptCount)),
         job.lastError.map { .text($0) } ?? .null,
         job.modelVersion.map { .text($0) } ?? .null,
         .date(job.createdAt), .date(job.updatedAt)]
    }

    private func mapChunkRecord(_ statement: OpaquePointer) -> ChunkRecord {
        let id = ArchiveDatabase.uuid(statement, 0)
        let sessionID = ArchiveDatabase.uuid(statement, 1)
        return ChunkRecord(
            id: id,
            sessionID: sessionID,
            fileName: ArchiveDatabase.text(statement, 2),
            relativePath: ArchiveDatabase.text(statement, 3),
            sha256: ArchiveDatabase.text(statement, 4),
            byteCount: Int(sqlite3_column_int64(statement, 5)),
            sequenceNumber: Int(sqlite3_column_int64(statement, 6)),
            metadata: (try? decode(AudioChunkMetadata.self,
                                   from: ArchiveDatabase.text(statement, 7)))
                ?? AudioChunkMetadata(
                    id: id, sessionID: sessionID,
                    fileName: ArchiveDatabase.text(statement, 2),
                    format: AudioChunkFormat(container: "", codec: "", sampleRate: 0),
                    integrity: ChunkIntegrity(
                        sha256Hex: ArchiveDatabase.text(statement, 4),
                        byteCount: Int(sqlite3_column_int64(statement, 5)),
                        duration: 0, sequenceNumber: 0,
                        monotonicStartSeconds: 0, monotonicEndSeconds: 0,
                        wallStartedAt: .distantPast, wallEndedAt: .distantPast
                    )
                ),
            receivedAt: ArchiveDatabase.date(statement, 8),
            state: ArchiveDatabase.text(statement, 9)
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try jsonEncoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try jsonDecoder.decode(type, from: Data(string.utf8))
    }
}
