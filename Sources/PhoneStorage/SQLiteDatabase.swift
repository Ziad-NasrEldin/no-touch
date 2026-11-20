import Foundation
import SQLite3
import RecorderContracts

/// `SQLITE_TRANSIENT` is a cast macro that Swift cannot import; this is the
/// standard idiom for "SQLite takes ownership of the bound bytes".
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Bound statement parameter. Kept minimal and explicit so every write is
/// auditable — no string interpolation of user data anywhere in the store.
enum SQLiteValue: Sendable {
    case text(String)
    case int(Int64)
    case real(Double)
    case null

    static func uuid(_ id: UUID) -> SQLiteValue { .text(id.uuidString) }
    static func uuid(_ id: UUID?) -> SQLiteValue { id.map { .text($0.uuidString) } ?? .null }
    static func date(_ date: Date) -> SQLiteValue { .real(date.timeIntervalSince1970) }
    static func date(_ date: Date?) -> SQLiteValue { date.map { .real($0.timeIntervalSince1970) } ?? .null }
    static func bool(_ flag: Bool) -> SQLiteValue { .int(flag ? 1 : 0) }
}

/// Single-owner SQLite connection. NOT an actor: all methods are synchronous
/// and this object is owned exclusively by `SQLiteArchiveStore`'s actor, whose
/// methods never suspend between database calls — that pairing is what makes
/// transactions atomic (an actor-isolated sequence of synchronous calls cannot
/// be interleaved by another task). Do not share this handle across actors.
final class ArchiveDatabase {
    private var db: OpaquePointer?
    private let fileURL: URL
    private(set) var schemaVersion = 0

    /// Bump whenever the schema changes; migrations run in order, additively.
    static let currentSchemaVersion = 2

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var isOpen: Bool { db != nil }

    func open() throws {
        guard db == nil else { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw RecorderError.storageFailure
        }
        db = handle
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 5000")
            try execute("PRAGMA synchronous = NORMAL")
            try migrate()
        } catch {
            sqlite3_close_v2(handle)
            db = nil
            throw error
        }
    }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: - Execution helpers

    /// Executes a statement expected to return no rows.
    func execute(_ sql: String, _ params: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RecorderError.storageFailure
        }
        defer { sqlite3_finalize(statement) }
        try bind(params, to: statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw RecorderError.storageFailure
        }
    }

    /// Runs a query and maps every row. `row` may throw to abort mapping.
    func query<T>(
        _ sql: String,
        _ params: [SQLiteValue] = [],
        row: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RecorderError.storageFailure
        }
        defer { sqlite3_finalize(statement) }
        try bind(params, to: statement)
        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                results.append(try row(statement))
            } else if step == SQLITE_DONE {
                return results
            } else {
                throw RecorderError.storageFailure
            }
        }
    }

    /// Returns the first row by stepping once. No `LIMIT` suffix is appended —
    /// that syntax is illegal on `PRAGMA` statements, which this layer also runs.
    func querySingle<T>(
        _ sql: String,
        _ params: [SQLiteValue] = [],
        row: (OpaquePointer) throws -> T
    ) throws -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RecorderError.storageFailure
        }
        defer { sqlite3_finalize(statement) }
        try bind(params, to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW {
            return try row(statement)
        } else if step == SQLITE_DONE {
            return nil
        } else {
            throw RecorderError.storageFailure
        }
    }

    func scalarInt(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int64 {
        try querySingle(sql, params) { sqlite3_column_int64($0, 0) } ?? 0
    }

    /// Runs work inside an IMMEDIATE transaction. The closure is synchronous
    /// so the BEGIN→work→COMMIT sequence cannot be interleaved by other
    /// store work (see ownership note on the class).
    func inTransaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try work()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func bind(_ params: [SQLiteValue], to statement: OpaquePointer) throws {
        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch param {
            case .text(let value):
                result = sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
            case .int(let value):
                result = sqlite3_bind_int64(statement, position, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, position, value)
            case .null:
                result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else { throw RecorderError.storageFailure }
        }
    }

    // MARK: - Column readers (statement position-based)

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    static func uuid(_ statement: OpaquePointer, _ column: Int32) -> UUID {
        UUID(uuidString: text(statement, column)) ?? UUID()
    }

    static func optionalUUID(_ statement: OpaquePointer, _ column: Int32) -> UUID? {
        optionalText(statement, column).flatMap(UUID.init(uuidString:))
    }

    static func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    static func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    // MARK: - Schema & migrations
    //
    // Migration posture: `PRAGMA user_version` is the single version marker.
    // Migrations are strictly additive (new tables/columns via ALTER … ADD),
    // idempotent, and run inside one transaction at open. Destructive schema
    // changes require a new version step that copies data forward — never an
    // in-place DROP of content-bearing tables.

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version")
        if version >= ArchiveDatabase.currentSchemaVersion {
            schemaVersion = Int(version)
            return
        }
        try inTransaction {
            if version < 1 {
                for statement in ArchiveSchema.version1 {
                    try execute(statement)
                }
            }
            if version < 2 {
                for statement in ArchiveSchema.version2 {
                    try execute(statement)
                }
            }
            try execute("PRAGMA user_version = \(ArchiveDatabase.currentSchemaVersion)")
        }
        schemaVersion = ArchiveDatabase.currentSchemaVersion
    }
}

enum ArchiveSchema {
    /// v2: per-segment diarized speaker label.
    static let version2: [String] = [
        "ALTER TABLE segments ADD COLUMN speaker_id INTEGER",
    ]

    static let version1: [String] = [
        // Recording sessions — phone-side mirror of capture truth.
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            failure_reason TEXT,
            started_at REAL,
            stopped_at REAL,
            last_confirmed_capture_at REAL,
            interruptions_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        // Durable received-chunk registry — this IS the dedup index.
        // state: stored | expired | deleted. Rows are never removed so the
        // audit trail of what was durably received (and later expired/deleted)
        // survives; tombstone semantics live in deletion_intents.
        """
        CREATE TABLE IF NOT EXISTS chunks (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            file_name TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            sequence_number INTEGER NOT NULL,
            metadata_json TEXT NOT NULL,
            received_at REAL NOT NULL,
            state TEXT NOT NULL DEFAULT 'stored'
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_chunks_session ON chunks(session_id, sequence_number)",

        // Transcript segments; normalized_text feeds the search postings.
        """
        CREATE TABLE IF NOT EXISTS segments (
            id TEXT PRIMARY KEY,
            chunk_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            start_time REAL NOT NULL,
            end_time REAL NOT NULL,
            wall_start_time REAL,
            text TEXT NOT NULL,
            normalized_text TEXT NOT NULL,
            language_spans_json TEXT NOT NULL,
            confidence REAL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_segments_session ON segments(session_id)",
        "CREATE INDEX IF NOT EXISTS idx_segments_chunk ON segments(chunk_id)",

        // Maintained inverted index (chosen over FTS5 — see module docs).
        // term is the normalized token; prefix-range queries power search.
        """
        CREATE TABLE IF NOT EXISTS search_terms (
            term TEXT NOT NULL,
            segment_id TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_search_terms_term ON search_terms(term, segment_id)",
        "CREATE INDEX IF NOT EXISTS idx_search_terms_segment ON search_terms(segment_id)",

        """
        CREATE TABLE IF NOT EXISTS groups (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            is_provisional INTEGER NOT NULL,
            started_at REAL,
            ended_at REAL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_groups_session ON groups(session_id)",

        """
        CREATE TABLE IF NOT EXISTS group_membership (
            conversation_id TEXT NOT NULL,
            segment_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY (conversation_id, segment_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_membership_segment ON group_membership(segment_id)",

        """
        CREATE TABLE IF NOT EXISTS generated_metadata (
            conversation_id TEXT PRIMARY KEY,
            title TEXT,
            summary TEXT,
            suggested_category TEXT,
            decisions_json TEXT NOT NULL,
            action_items_json TEXT NOT NULL,
            sources_json TEXT NOT NULL,
            model_version TEXT NOT NULL,
            generated_at REAL NOT NULL
        )
        """,

        // User edits. Latest record per (conversation, field) wins on read;
        // generated writes never replace overridden fields in effective views.
        """
        CREATE TABLE IF NOT EXISTS overrides (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            field TEXT NOT NULL,
            value TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_overrides_conv ON overrides(conversation_id, field)",

        // Tombstones. Checked by every ingest/upsert path so delayed or
        // duplicate deliveries can never resurrect deleted content.
        """
        CREATE TABLE IF NOT EXISTS deletion_intents (
            id TEXT PRIMARY KEY,
            target TEXT NOT NULL,
            target_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            propagated_to_watch INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_deletion_target ON deletion_intents(target, target_id)",

        """
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            chunk_id TEXT,
            conversation_id TEXT,
            attempt_count INTEGER NOT NULL,
            last_error TEXT,
            model_version TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state, kind, created_at)",
        "CREATE INDEX IF NOT EXISTS idx_jobs_chunk ON jobs(chunk_id)",
        "CREATE INDEX IF NOT EXISTS idx_jobs_conv ON jobs(conversation_id)",

        // Structured evidence ring. Payloads carry counts/states/timings only.
        """
        CREATE TABLE IF NOT EXISTS diagnostics (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL,
            ts REAL NOT NULL,
            subsystem TEXT NOT NULL,
            severity TEXT NOT NULL,
            name TEXT NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_diagnostics_ts ON diagnostics(ts)",
    ]
}
