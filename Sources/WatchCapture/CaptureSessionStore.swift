import Foundation
import RecorderContracts

/// Persisted capture position: the active session plus the sequence counter,
/// so a relaunched process can continue numbering and detect the gap it left.
struct PersistedCapture: Codable, Sendable {
    var session: RecordingSession
    var nextSequence: Int
}

/// Atomic JSON persistence for session state and per-session chunk manifests.
/// All writes go through `Data.write(.atomic)` (tmp file + rename) so a crash
/// mid-write can never leave a torn state file behind.
struct CaptureSessionStore: Sendable {
    let paths: CapturePaths

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

    func load() -> PersistedCapture? {
        guard let data = try? Data(contentsOf: paths.sessionFile) else { return nil }
        return try? decoder.decode(PersistedCapture.self, from: data)
    }

    func save(_ persisted: PersistedCapture) throws {
        let data = try encoder.encode(persisted)
        try data.write(to: paths.sessionFile, options: .atomic)
    }

    func loadManifest(sessionID: UUID) -> [AudioChunkMetadata] {
        guard let data = try? Data(contentsOf: paths.manifestFile(sessionID: sessionID)) else { return [] }
        return (try? decoder.decode([AudioChunkMetadata].self, from: data)) ?? []
    }

    func saveManifest(sessionID: UUID, chunks: [AudioChunkMetadata]) throws {
        let data = try encoder.encode(chunks)
        try data.write(to: paths.manifestFile(sessionID: sessionID), options: .atomic)
    }

    /// Chunk files on disk that no manifest claims — partial writes left by a
    /// crash. They are treated as unknown/missing audio, never as captured
    /// audio, and are removed to bound storage.
    func orphanedChunkFiles(sessionID: UUID, manifest: [AudioChunkMetadata]) -> [URL] {
        let directory = paths.chunksDirectory(sessionID: sessionID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let known = Set(manifest.map(\.fileName))
        return names
            .filter { !known.contains($0) }
            .map { directory.appendingPathComponent($0) }
    }

    /// Directories of sessions other than `keeping`, used to scan for orphans
    /// left by sessions that finalized before a crash.
    func allChunkSessionDirectories() -> [URL] {
        let chunksRoot = paths.root.appendingPathComponent("chunks", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: chunksRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
