import Foundation
import RecorderContracts

/// On-disk layout for everything `WatchCapture` persists. One app-owned root
/// keeps session truth, chunk payloads, manifests, the transfer outbox, and
/// diagnostics together so Gate A evidence and crash recovery read one tree.
struct CapturePaths: Sendable {
    let root: URL

    var sessionFile: URL { root.appendingPathComponent("session.json") }
    var outboxFile: URL { root.appendingPathComponent("outbox.json") }
    var diagnosticsFile: URL {
        root.appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    func chunksDirectory(sessionID: UUID) -> URL {
        root.appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func manifestFile(sessionID: UUID) -> URL {
        root.appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).json")
    }

    func url(for chunk: AudioChunkMetadata) -> URL {
        chunksDirectory(sessionID: chunk.sessionID)
            .appendingPathComponent(chunk.fileName)
    }

    /// Ensures the root and fixed subdirectories exist and marks the audio
    /// root excluded from backup so a paired-device backup cannot carry raw
    /// recordings off-device (spec: exclude recordings from cloud backup).
    static func makeDefault(fileManager: FileManager = .default) throws -> CapturePaths {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecorderError.storageFailure
        }
        return try makeCustom(root: support.appendingPathComponent("WatchCapture", isDirectory: true),
                              fileManager: fileManager)
    }

    static func makeCustom(root: URL, fileManager: FileManager = .default) throws -> CapturePaths {
        let paths = CapturePaths(root: root)
        for dir in [root,
                    root.appendingPathComponent("chunks", isDirectory: true),
                    root.appendingPathComponent("manifests", isDirectory: true),
                    root.appendingPathComponent("diagnostics", isDirectory: true)] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        #if os(iOS) || os(watchOS)
        // Raw capture root holds unencrypted audio — match the phone archive's
        // posture (first-unlock protection) instead of the looser default.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path
        )
        #endif
        return paths
    }
}
