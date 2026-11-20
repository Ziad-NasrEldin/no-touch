import Foundation
import RecorderContracts

/// Persisted capture position: the active session plus the sequence counter,
/// so a relaunched process can continue numbering and detect the gap it left.
public struct PersistedCapture: Codable, Sendable {
    public var session: RecordingSession
    public var nextSequence: Int

    public init(session: RecordingSession, nextSequence: Int) {
        self.session = session
        self.nextSequence = nextSequence
    }
}

/// Atomic JSON persistence for session state and per-session chunk manifests.
/// All writes go through `Data.write(.atomic)` (tmp file + rename) so a crash
/// mid-write can never leave a torn state file behind.
public struct CaptureSessionStore: Sendable {
    public let paths: CapturePaths

    public init(paths: CapturePaths) {
        self.paths = paths
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func load() -> PersistedCapture? {
        guard let data = try? Data(contentsOf: paths.sessionFile) else { return nil }
        return try? decoder.decode(PersistedCapture.self, from: data)
    }

    public func save(_ persisted: PersistedCapture) throws {
        let data = try encoder.encode(persisted)
        try data.write(to: paths.sessionFile, options: .atomic)
    }

    public func loadManifest(sessionID: UUID) -> [AudioChunkMetadata] {
        guard let data = try? Data(contentsOf: paths.manifestFile(sessionID: sessionID)) else { return [] }
        return (try? decoder.decode([AudioChunkMetadata].self, from: data)) ?? []
    }

    public func saveManifest(sessionID: UUID, chunks: [AudioChunkMetadata]) throws {
        let data = try encoder.encode(chunks)
        try data.write(to: paths.manifestFile(sessionID: sessionID), options: .atomic)
    }

    /// All session IDs that have a persisted manifest JSON on disk.
    public func allManifestSessionIDs() -> [UUID] {
        let manifestsDir = paths.root.appendingPathComponent("manifests", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: manifestsDir.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(".json".count)))
        }
    }

    /// Chunk files on disk that no manifest claims — partial writes left by a
    /// crash. They are treated as unknown/missing audio, never as captured
    /// audio, and are removed to bound storage.
    public func orphanedChunkFiles(sessionID: UUID, manifest: [AudioChunkMetadata]) -> [URL] {
        let directory = paths.chunksDirectory(sessionID: sessionID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let known = Set(manifest.map(\.fileName))
        return names
            .filter { !known.contains($0) }
            .map { directory.appendingPathComponent($0) }
    }

    /// Directories of sessions under `chunks/`, used to scan for orphans left
    /// by sessions that finalized before a crash.
    public func allChunkSessionDirectories() -> [URL] {
        let chunksRoot = paths.root.appendingPathComponent("chunks", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: chunksRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
