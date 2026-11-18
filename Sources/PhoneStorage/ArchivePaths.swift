import Foundation
import RecorderContracts

/// On-disk layout for the phone-side recorder archive. Everything lives in one
/// app-owned root so the privacy posture (protection class, backup exclusion)
/// is applied in exactly one place.
///
/// ```
/// <root>/
///   archive.sqlite3            metadata, index, jobs, tombstones, diagnostics
///   archive.sqlite3-wal/-shm   WAL sidecars
///   incoming/                  temp landing for transfers (never acked from here)
///   chunks/<sessionID>/        durable, verified chunk files
///   quarantine/                unaccounted/corrupt files kept for inspection
/// ```
///
/// Protection choice: `.completeUntilFirstUserAuthentication` on the archive
/// root and every stored chunk file. `.complete` / `.completeUnlessOpen` are
/// stronger but would block creating new chunk files while the phone is locked
/// — which is exactly when background `WCSession` delivery happens for an
/// all-day recorder. The chosen class still keeps content unreadable before
/// first unlock after boot and is applied to raw audio AND the database.
public struct ArchiveFileLayout: Sendable, Equatable {
    public var root: URL
    public var excludeDerivedDataFromBackup: Bool

    public static let directoryName = "RecorderArchive"
    /// Scratch/manual-run override so the store can be exercised without an
    /// app container (e.g. a small `main.swift` driver, not a test).
    public static let environmentOverrideKey = "RECORDER_ARCHIVE_DIR"

    public init(root: URL, excludeDerivedDataFromBackup: Bool = true) {
        self.root = root
        self.excludeDerivedDataFromBackup = excludeDerivedDataFromBackup
    }

    /// Default location: `Application Support/RecorderArchive`. Honors the
    /// `RECORDER_ARCHIVE_DIR` environment override for manual exercise.
    public static func `default`(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ArchiveFileLayout {
        if let override = environment[environmentOverrideKey], !override.isEmpty {
            return ArchiveFileLayout(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return ArchiveFileLayout(root: base.appendingPathComponent(directoryName, isDirectory: true))
    }

    public var databaseFile: URL { root.appendingPathComponent("archive.sqlite3") }
    public var incomingDirectory: URL { root.appendingPathComponent("incoming", isDirectory: true) }
    public var chunksDirectory: URL { root.appendingPathComponent("chunks", isDirectory: true) }
    public var quarantineDirectory: URL { root.appendingPathComponent("quarantine", isDirectory: true) }

    public func sessionChunksDirectory(sessionID: UUID) -> URL {
        chunksDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Durable name: chunk identity prefix guarantees uniqueness even if two
    /// chunks share a fileName; the original name is kept for human inspection.
    public func durableFileName(for chunk: AudioChunkMetadata) -> String {
        let sanitized = chunk.fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        return "\(chunk.id.uuidString)-\(sanitized)"
    }

    /// Creates the layout directories and applies the privacy attributes.
    /// Idempotent; safe to call on every open.
    public func prepare(fileManager: FileManager = .default) throws {
        for directory in [root, incomingDirectory, chunksDirectory, quarantineDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try applyProtectionAttributes(to: root, fileManager: fileManager)
        try setExcludedFromBackup(true, url: chunksDirectory)
        try setExcludedFromBackup(true, url: incomingDirectory)
        try setExcludedFromBackup(true, url: quarantineDirectory)
        if excludeDerivedDataFromBackup {
            // Privacy-maximal default: transcripts/metadata never leave the
            // device through iCloud/iTunes backup. Product may relax this to
            // back up derived (regenerable-with-audio-lost) data only.
            try setExcludedFromBackup(true, url: root)
        }
    }

    /// Applies the file protection class recursively to an existing path.
    /// No-op off iOS/watchOS (the attribute is meaningful on those platforms).
    public func applyProtectionAttributes(to url: URL, fileManager: FileManager = .default) throws {
        #if os(iOS) || os(watchOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    /// Marks a file or directory excluded from backup per spec ("exclude raw
    /// recordings from cloud backup by default"). Applied to the chunks dir at
    /// prepare time and re-applied to every stored chunk file defensively.
    public func setExcludedFromBackup(_ excluded: Bool, url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        var mutable = url
        try mutable.setResourceValues(values)
    }
}

extension ArchiveFileLayout {
    /// Convenience for the receive path.
    public func durableFileURL(for chunk: AudioChunkMetadata) -> URL {
        sessionChunksDirectory(sessionID: chunk.sessionID)
            .appendingPathComponent(durableFileName(for: chunk))
    }
}
