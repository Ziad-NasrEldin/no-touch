import CryptoKit
import Foundation
import RecorderContracts

/// Persisted readiness snapshot for one model descriptor. Mirrors the frozen
/// `ModelReadinessState` vocabulary and adds progress/bytes/failure detail so
/// the install UX can render honest state without another channel.
public struct ModelInstallSnapshot: Codable, Sendable, Equatable {
    public var descriptorID: String
    public var state: ModelReadinessState
    /// 0...1. Stays at last known value on failure so the UI can show where
    /// a download stopped.
    public var progress: Double
    public var downloadedBytes: Int64
    public var expectedBytes: Int64?
    public var modelVersion: String?
    /// Directory that passed verification and feeds `engine.load`. For
    /// repository installs this is the resolved snapshot directory inside the
    /// model's install root.
    public var installDirectory: String?
    public var failureReason: String?
    public var updatedAt: Date

    public init(
        descriptorID: String,
        state: ModelReadinessState,
        progress: Double = 0,
        downloadedBytes: Int64 = 0,
        expectedBytes: Int64? = nil,
        modelVersion: String? = nil,
        installDirectory: String? = nil,
        failureReason: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.descriptorID = descriptorID
        self.state = state
        self.progress = progress
        self.downloadedBytes = downloadedBytes
        self.expectedBytes = expectedBytes
        self.modelVersion = modelVersion
        self.installDirectory = installDirectory
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }
}

/// Performs the byte movement for one `ModelInstallMethod`. Returning the
/// *resolved* directory matters: repository downloaders (Hugging Face layout)
/// nest the real model folder several levels below the install root.
public protocol ModelContentDownloader: Sendable {
    /// Download (or resume) the descriptor's bytes under `directory`.
    /// `progress(downloadedBytes, expectedTotalBytes)` may be called on any
    /// thread; totals may be estimates when the repository reports units
    /// other than bytes. Must return the directory that contains the usable
    /// model and must throw on failure/cancellation (partial bytes may stay
    /// on disk for the next attempt).
    func download(
        descriptor: ModelDescriptor,
        into directory: URL,
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws -> URL

    /// Post-install integrity check on the resolved model directory.
    func verify(descriptor: ModelDescriptor, installedAt directory: URL) async -> Bool
}

/// Resolves a downloader for an install method. Repository methods return
/// nil when their package isn't compiled into this target yet — that's an
/// actionable `unsupportedInstallMethod` for I1, not a silent fallback.
enum ModelDownloaderResolver {
    static func downloader(for method: ModelInstallMethod) -> (any ModelContentDownloader)? {
        switch method {
        case .files:
            return URLSessionModelDownloader()
        case .whisperKitRepository:
            #if canImport(WhisperKit)
            return WhisperKitModelDownloader()
            #else
            return nil
            #endif
        case .mlxRepository:
            #if canImport(MLXLMCommon)
            return MLXRepositoryDownloader()
            #else
            return nil
            #endif
        }
    }
}

/// Durable readiness state machine for one `ModelDescriptor`:
///
///     notInstalled ──install()──▶ downloading ──▶ verifying ──▶ ready
///                       │               │              │
///                       └───────────────┴──────────────┴──▶ failed
///
/// Rules honored: downloads start ONLY from `install()` (the user-visible
/// install flow hook) — nothing here auto-downloads on first use; state is
/// persisted to `install-record.json` inside the model directory and
/// reloaded across launches; a record stuck in downloading/verifying at
/// launch is normalized to `.failed("interrupted")` rather than pretending
/// progress continues; inference is offline afterward (engines load purely
/// from `installDirectory`).
public actor ModelInstallController {
    public let descriptor: ModelDescriptor
    public let rootDirectory: URL

    private var snapshotValue: ModelInstallSnapshot
    private var continuations: [UUID: AsyncStream<ModelInstallSnapshot>.Continuation] = [:]
    private var installTask: Task<Void, Error>?
    private let downloaderOverride: (any ModelContentDownloader)?
    private var lastProgressEmitAt: Date = .distantPast
    private var lastProgressEmitValue: Double = -1
    private var lastProgressPersistAt: Date = .distantPast

    private static let recordFileName = "install-record.json"

    /// `rootDirectory` is the app-owned models root (backup-excluded by
    /// `PhoneAI.modelsRootDirectory`). Each descriptor owns one subdirectory.
    public init(
        descriptor: ModelDescriptor,
        rootDirectory: URL,
        downloaderOverride: (any ModelContentDownloader)? = nil
    ) throws {
        self.descriptor = descriptor
        self.rootDirectory = rootDirectory
        self.downloaderOverride = downloaderOverride

        let fm = FileManager.default
        let modelDir = rootDirectory.appendingPathComponent(descriptor.id, isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let recordURL = modelDir.appendingPathComponent(Self.recordFileName)
        if let data = try? Data(contentsOf: recordURL),
           var record = try? JSONDecoder().decode(ModelInstallSnapshot.self, from: data)
        {
            var needsPersist = false
            // A persisted in-flight state means the process died mid-install:
            // the download didn't finish, so present an honest resumable
            // failure rather than a stalled "downloading".
            if record.state == .downloading || record.state == .verifying {
                record.state = .failed
                record.failureReason = "install interrupted before verification — start install again to resume"
                record.updatedAt = Date()
                needsPersist = true
            } else if record.state == .ready {
                // Rebase absolute install paths across iOS app-container UUID
                // rotations (e.g. TestFlight / Xcode reinstalls), and refuse to
                // claim `.ready` if the verified model directory is gone.
                if let resolved = Self.resolveStoredInstallDirectory(
                    record.installDirectory,
                    descriptorID: descriptor.id,
                    modelDirectory: modelDir,
                    fileManager: fm
                ) {
                    let stored = Self.storableInstallPath(for: resolved, under: modelDir)
                    if record.installDirectory != stored {
                        record.installDirectory = stored
                        record.updatedAt = Date()
                        needsPersist = true
                    }
                } else {
                    record.state = .notInstalled
                    record.progress = 0
                    record.downloadedBytes = 0
                    record.installDirectory = nil
                    record.failureReason = "Model files were missing on disk — tap Install models to download again."
                    record.updatedAt = Date()
                    needsPersist = true
                }
            }
            snapshotValue = record
            if needsPersist, let encoded = try? JSONEncoder().encode(record) {
                try? encoded.write(to: recordURL, options: .atomic)
            }
        } else {
            snapshotValue = ModelInstallSnapshot(
                descriptorID: descriptor.id,
                state: .notInstalled,
                expectedBytes: descriptor.expectedBytes,
                modelVersion: descriptor.modelVersion
            )
        }
    }

    /// Directory the descriptor's bytes live under.
    public nonisolated var modelDirectory: URL {
        rootDirectory.appendingPathComponent(descriptor.id, isDirectory: true)
    }

    /// Resolves the live on-disk install directory for a `.ready` snapshot,
    /// transparently rebasing legacy absolute paths across iOS sandbox container
    /// UUID changes. Returns nil if the model is not ready or missing on disk.
    public func resolvedInstallDirectory() -> URL? {
        guard snapshotValue.state == .ready else { return nil }
        guard let resolved = Self.resolveStoredInstallDirectory(
            snapshotValue.installDirectory,
            descriptorID: descriptor.id,
            modelDirectory: modelDirectory,
            fileManager: .default
        ) else {
            update {
                $0.state = .notInstalled
                $0.progress = 0
                $0.downloadedBytes = 0
                $0.installDirectory = nil
                $0.failureReason = "Model files were missing on disk — tap Install models to download again."
            }
            return nil
        }
        return resolved
    }

    private static func storableInstallPath(for resolved: URL, under modelDir: URL) -> String {
        let basePath = modelDir.standardizedFileURL.path
        let targetPath = resolved.standardizedFileURL.path
        if targetPath == basePath { return "." }
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        if targetPath.hasPrefix(prefix) {
            return String(targetPath.dropFirst(prefix.count))
        }
        return targetPath
    }

    private static func resolveStoredInstallDirectory(
        _ storedPath: String?,
        descriptorID: String,
        modelDirectory: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let storedPath, !storedPath.isEmpty else { return nil }
        var isDir: ObjCBool = false

        // 1. Relative path under modelDirectory (new format).
        if !storedPath.hasPrefix("/") {
            let candidate = storedPath == "."
                ? modelDirectory
                : modelDirectory.appendingPathComponent(storedPath, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }

        // 2. Existing absolute path (same container / macOS).
        if storedPath.hasPrefix("/"),
           fileManager.fileExists(atPath: storedPath, isDirectory: &isDir),
           isDir.boolValue
        {
            return URL(fileURLWithPath: storedPath, isDirectory: true)
        }

        // 3. Legacy absolute path from a previous iOS container UUID:
        // extract the suffix after `/<descriptorID>/` and rebase onto `modelDirectory`.
        let marker = "/\(descriptorID)/"
        if let range = storedPath.range(of: marker, options: .backwards) {
            let suffix = String(storedPath[range.upperBound...])
            if !suffix.isEmpty {
                let rebased = modelDirectory.appendingPathComponent(suffix, isDirectory: true)
                if fileManager.fileExists(atPath: rebased.path, isDirectory: &isDir), isDir.boolValue {
                    return rebased
                }
            }
        }
        return nil
    }

    public func snapshot() -> ModelInstallSnapshot { snapshotValue }

    /// Latest-value stream for the install UX; replays the current snapshot
    /// to new subscribers first.
    public func snapshots() -> AsyncStream<ModelInstallSnapshot> {
        let id = UUID()
        let initial = snapshotValue
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Explicit install entry point — the only path that downloads. Safe to
    /// call again after `failed` or `cancelled`: partial bytes are reused by
    /// the downloader where the method supports resume.
    public func install() async throws {
        switch snapshotValue.state {
        case .ready, .downloading, .verifying:
            return
        case .notInstalled, .failed:
            break
        }

        try ensureFreeSpace()
        guard
            let downloader = downloaderOverride ?? ModelDownloaderResolver.downloader(for: descriptor.installMethod)
        else {
            throw PhoneAIError.unsupportedInstallMethod(
                "no downloader compiled for \(descriptor.installMethod) — register the matching SPM product"
            )
        }

        lastProgressEmitAt = .distantPast
        lastProgressEmitValue = -1
        lastProgressPersistAt = .distantPast
        update { $0.state = .downloading; $0.failureReason = nil }

        // The transfer runs in its own task so `cancelInstall()` can abort it
        // even when the caller awaits `install()` on a different task.
        let task = Task { [descriptor, downloader, modelDirectory, weak self] in
            let resolved = try await downloader.download(
                descriptor: descriptor,
                into: modelDirectory
            ) { [weak self] downloaded, total in
                Task { await self?.recordProgress(downloaded: downloaded, expected: total) }
            }
            await self?.enterVerifying()
            guard await downloader.verify(descriptor: descriptor, installedAt: resolved) else {
                throw PhoneAIError.verificationFailed("model directory failed integrity check")
            }
            await self?.enterReady(installDirectory: resolved)
        }
        installTask = task
        defer { installTask = nil }

        do {
            try await task.value
        } catch is CancellationError {
            update {
                $0.state = .failed
                $0.failureReason = "install cancelled — partial download kept for resume"
            }
            throw CancellationError()
        } catch {
            update {
                $0.state = .failed
                $0.failureReason = error.localizedDescription
            }
            throw error
        }
    }

    /// Cancels an in-flight install. Partial bytes stay on disk so the next
    /// `install()` resumes where it stopped.
    public func cancelInstall() {
        installTask?.cancel()
    }

    /// Removes the model and its record. Explicit cleanup only — never
    /// triggered implicitly.
    public func uninstall() throws {
        installTask?.cancel()
        try FileManager.default.removeItem(at: modelDirectory)
        snapshotValue = ModelInstallSnapshot(
            descriptorID: descriptor.id,
            state: .notInstalled,
            expectedBytes: descriptor.expectedBytes,
            modelVersion: descriptor.modelVersion
        )
        emit()
    }

    // MARK: - Transitions

    private func recordProgress(downloaded: Int64, expected: Int64?) {
        guard snapshotValue.state == .downloading else { return }
        let total = expected ?? descriptor.expectedBytes
        let nextDownloaded = max(snapshotValue.downloadedBytes, downloaded)
        var nextProgress = snapshotValue.progress
        if let total, total > 0 {
            nextProgress = max(nextProgress, min(0.999, Double(nextDownloaded) / Double(total)))
        }

        let now = Date()
        let deltaProgress = nextProgress - lastProgressEmitValue
        let sinceEmit = now.timeIntervalSince(lastProgressEmitAt)
        let shouldEmit = lastProgressEmitValue < 0 || deltaProgress >= 0.005 || sinceEmit >= 0.15
        let shouldPersist = now.timeIntervalSince(lastProgressPersistAt) >= 1.0

        snapshotValue.downloadedBytes = nextDownloaded
        snapshotValue.expectedBytes = total
        snapshotValue.progress = nextProgress
        snapshotValue.updatedAt = now

        if shouldPersist {
            lastProgressPersistAt = now
            persist()
        }
        if shouldEmit {
            lastProgressEmitAt = now
            lastProgressEmitValue = nextProgress
            emit()
        }
    }

    private func enterVerifying() {
        lastProgressEmitAt = .distantPast
        lastProgressEmitValue = -1
        lastProgressPersistAt = .distantPast
        update { $0.state = .verifying; $0.progress = max($0.progress, 0.99) }
    }

    private func enterReady(installDirectory: URL) {
        let storable = Self.storableInstallPath(for: installDirectory, under: modelDirectory)
        update {
            $0.state = .ready
            $0.progress = 1
            $0.installDirectory = storable
            $0.failureReason = nil
        }
    }

    private func update(_ mutate: (inout ModelInstallSnapshot) -> Void) {
        mutate(&snapshotValue)
        snapshotValue.updatedAt = Date()
        persist()
        emit()
    }

    private func emit() {
        for continuation in continuations.values {
            continuation.yield(snapshotValue)
        }
    }

    private func persist() {
        let recordURL = modelDirectory.appendingPathComponent(Self.recordFileName)
        if let data = try? JSONEncoder().encode(snapshotValue) {
            try? data.write(to: recordURL, options: .atomic)
        }
    }

    private func ensureFreeSpace() throws {
        guard descriptor.minimumFreeBytes > 0 else { return }
        let values = try rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < descriptor.minimumFreeBytes
        {
            throw RecorderError.lowStorage
        }
    }
}

// MARK: - Direct-URL downloader (`.files`)

/// URLSession-based downloader for descriptors declared as plain files.
/// Writes `*.partial` siblings of each destination and resumes them with an
/// HTTP Range request on the next attempt; verifies byte count and SHA-256
/// when the descriptor declares them.
public struct URLSessionModelDownloader: ModelContentDownloader {
    public init() {}

    public func download(
        descriptor: ModelDescriptor,
        into directory: URL,
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws -> URL {
        guard case .files(let files) = descriptor.installMethod else {
            throw PhoneAIError.unsupportedInstallMethod("URLSessionModelDownloader only handles .files")
        }
        let fm = FileManager.default
        var completedBytes: Int64 = 0
        let expectedTotal = descriptor.expectedBytes

        for file in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.relativePath)
            let partial = destination.appendingPathExtension("partial")
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var resumeOffset: Int64 = 0
            if let size = try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64,
               size > 0
            {
                resumeOffset = size
            }

            var request = URLRequest(url: file.url)
            if resumeOffset > 0 {
                request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            }

            let base = completedBytes
            let staged = try await DownloadTransfer(request: request, resumeOffset: resumeOffset).run { written in
                progress(base + written, expectedTotal)
            }

            if staged.statusCode == 206, resumeOffset > 0 {
                // Server honored Range: append the tail onto .partial.
                let out = try FileHandle(forWritingTo: partial)
                let input = try FileHandle(forReadingFrom: staged.file)
                defer { try? input.close(); try? out.close() }
                try out.seekToEnd()
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try out.write(contentsOf: chunk)
                }
                try out.synchronize()
                try fm.removeItem(at: staged.file)
            } else {
                // Fresh download, or server ignored Range (200): staged file
                // is the complete payload — replace the partial.
                try? fm.removeItem(at: partial)
                try fm.moveItem(at: staged.file, to: partial)
            }
            try fm.moveItem(at: partial, to: destination)
            completedBytes += file.expectedBytes ?? resumeOffset
        }
        return directory
    }

    public func verify(descriptor: ModelDescriptor, installedAt directory: URL) async -> Bool {
        guard case .files(let files) = descriptor.installMethod else { return false }
        let fm = FileManager.default
        for file in files {
            let url = directory.appendingPathComponent(file.relativePath)
            guard fm.fileExists(atPath: url.path) else { return false }
            if let expected = file.expectedBytes,
               let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64,
               size != expected
            {
                return false
            }
            if let expectedHex = file.sha256Hex,
               let digest = sha256Hex(of: url),
               digest.caseInsensitiveCompare(expectedHex) != .orderedSame
            {
                return false
            }
        }
        return true
    }

    private func sha256Hex(of url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { return nil }
            if read == 0 { break }
            buffer.withUnsafeBytes {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress, count: read))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Completion-based `URLSessionDownloadTask` wrapper — per-byte async byte
/// streams are far too slow for multi-hundred-MB models.
private struct DownloadTransfer: @unchecked Sendable {
    struct Result {
        var file: URL
        var statusCode: Int?
    }

    let request: URLRequest
    let resumeOffset: Int64

    init(request: URLRequest, resumeOffset: Int64) {
        self.request = request
        self.resumeOffset = resumeOffset
    }

    func run(progress: @Sendable @escaping (Int64) -> Void) async throws -> Result {
        final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
            var progress: (@Sendable (Int64) -> Void)?
            var resumeOffset: Int64 = 0
            var stagedURL: URL?
            var statusCode: Int?
            var finish: ((Swift.Result<DownloadTransfer.Result, Error>) -> Void)?
            var didResume = false

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didWriteData bytesWritten: Int64,
                totalBytesWritten: Int64,
                totalBytesExpectedToWrite: Int64
            ) {
                progress?(totalBytesWritten + resumeOffset)
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didFinishDownloadingTo location: URL
            ) {
                // Move synchronously: the temp file is deleted on return.
                do {
                    let staged = location.deletingLastPathComponent()
                        .appendingPathComponent("a1-dl-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: location, to: staged)
                    stagedURL = staged
                } catch {
                    complete(.failure(error))
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                statusCode = (task.response as? HTTPURLResponse)?.statusCode
                if let error {
                    complete(.failure(error))
                } else if let stagedURL {
                    complete(.success(.init(file: stagedURL, statusCode: statusCode)))
                } else {
                    complete(.failure(PhoneAIError.verificationFailed("download produced no file")))
                }
            }

            private func complete(_ result: Swift.Result<DownloadTransfer.Result, Error>) {
                guard !didResume else { return }
                didResume = true
                finish?(result)
            }
        }

        let delegate = Delegate()
        delegate.resumeOffset = resumeOffset
        delegate.progress = { written in
            Task.detached { progress(written) }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.finish = { result in
                    session.finishTasksAndInvalidate()
                    continuation.resume(with: result)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}
