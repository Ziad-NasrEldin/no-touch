import AudioCapture
import Foundation
import RecorderContracts

/// Re-exported permission state so iPhone app code can inspect microphone
/// status through `PhoneIntegration` without depending on `AudioCapture`.
public typealias PhoneMicrophonePermission = AudioCapture.MicrophonePermission

/// iPhone-local capture service backed by the shared `ChunkedCaptureService`.
///
/// Mirrors `WatchCaptureService` (60 s mono 16 kHz AAC `.m4a` chunks, atomic
/// session + manifest persistence, honest gap/interruption tracking, relaunch
/// recovery), but feeds finalized chunks directly into `SessionCoordinator`'s
/// `PhoneReceiveService` ingest path instead of a WatchConnectivity outbox.
/// Every phone-captured chunk therefore lands in the exact same SQLite archive
/// and transcription/grouping/analysis pipeline as watch-captured chunks.
public actor PhoneCaptureService: AudioCaptureServiceProtocol {
    public static let defaultChunkDuration: TimeInterval = ChunkedCaptureService.defaultChunkDuration

    private let core: ChunkedCaptureService
    private let coordinator: SessionCoordinator
    private let diagnostics: CaptureDiagnostics
    private var ingestingChunkIDs: Set<UUID> = []
    private nonisolated(unsafe) var stateMirrorTask: Task<Void, Never>?

    public init(
        coordinator: SessionCoordinator,
        diagnostics: CaptureDiagnostics? = nil,
        directory: URL? = nil,
        chunkDuration: TimeInterval = PhoneCaptureService.defaultChunkDuration,
        beforeActivateAudioSession: (@Sendable () async -> Void)? = nil
    ) {
        self.coordinator = coordinator
        let resolvedDiagnostics: CaptureDiagnostics
        if let diagnostics {
            resolvedDiagnostics = diagnostics
        } else if let directory {
            resolvedDiagnostics = CaptureDiagnostics(directory: directory, defaultFolderName: "PhoneCapture")
        } else {
            resolvedDiagnostics = CaptureDiagnostics(defaultFolderName: "PhoneCapture")
        }
        self.diagnostics = resolvedDiagnostics
        let relay = ChunkHandoffRelay()
        self.core = ChunkedCaptureService(
            defaultFolderName: "PhoneCapture",
            directory: directory,
            diagnostics: resolvedDiagnostics,
            chunkDuration: chunkDuration,
            beforeActivateAudioSession: beforeActivateAudioSession,
            onChunkFinalized: { metadata, fileURL in
                await relay.call(metadata, fileURL)
            }
        )
        bindHandoff(relay)
        self.stateMirrorTask = makeStateMirrorPump(
            stream: core.stateUpdates(),
            coordinator: coordinator
        )
    }

    deinit {
        stateMirrorTask?.cancel()
    }

    private nonisolated func bindHandoff(_ relay: ChunkHandoffRelay) {
        relay.handler = { [weak self] metadata, fileURL in
            await self?.ingestChunk(metadata: metadata, fileURL: fileURL)
        }
    }

    private nonisolated func makeStateMirrorPump(
        stream: AsyncStream<RecordingSession>,
        coordinator: SessionCoordinator
    ) -> Task<Void, Never> {
        Task {
            var isFirst = true
            for await snapshot in stream {
                if isFirst {
                    isFirst = false
                    // Only mirror a recovered session on launch if it was
                    // interrupted/paused/recording; a stale stopped session
                    // from an earlier day should not overwrite an active
                    // watch session in live status UI.
                    if snapshot.state == .idle || snapshot.state == .stopped {
                        continue
                    }
                }
                await coordinator.recordLocalSession(snapshot)
            }
        }
    }

    public static nonisolated func microphonePermission() -> PhoneMicrophonePermission {
        ChunkedCaptureService.microphonePermission()
    }

    public static nonisolated var isPlatformSupported: Bool {
        ChunkedCaptureService.isPlatformSupported
    }

    // MARK: - AudioCaptureServiceProtocol

    public func startSession() async throws -> RecordingSession {
        try await core.startSession()
    }

    public func pauseSession() async throws -> RecordingSession {
        let updated = try await core.pauseSession()
        await core.awaitPendingFinalizations()
        return updated
    }

    public func resumeSession() async throws -> RecordingSession {
        try await core.resumeSession()
    }

    public func stopSession() async throws -> RecordingSession {
        let updated = try await core.stopSession()
        await core.awaitPendingFinalizations()
        return updated
    }

    public func currentSession() async -> RecordingSession? {
        await core.currentSession()
    }

    public func finalizedChunks(sessionID: UUID) async -> [AudioChunkMetadata] {
        await core.finalizedChunks(sessionID: sessionID)
    }

    public nonisolated func stateUpdates() -> AsyncStream<RecordingSession> {
        core.stateUpdates()
    }

    // MARK: - Local archive handoff & lifecycle

    /// Reconciles any finalized chunks whose staging files remain on disk
    /// (e.g. after a crash between sealing a chunk and archiving it).
    public func activate() async {
        await reconcilePendingChunks()
    }

    public func appDidBecomeActive() async {
        await core.appDidBecomeActive()
        await reconcilePendingChunks()
    }

    public func appWillResignActive() async {
        await core.appWillResignActive()
    }

    public func appDidEnterBackground() async {
        await core.appDidEnterBackground()
    }

    /// Number of finalized chunks for `sessionID` still awaiting local ingest
    /// into `PhoneReceiveService` (analogous to the Watch's queued count).
    public func pendingIngestCount(sessionID: UUID) async -> Int {
        let manifest = await core.finalizedChunks(sessionID: sessionID)
        let paths = await core.paths
        let fm = FileManager.default
        return manifest.reduce(into: 0) { count, chunk in
            if fm.fileExists(atPath: paths.url(for: chunk).path) {
                count += 1
            }
        }
    }

    public func reconcilePendingChunks() async {
        let pending = await core.unconsumedFinalizedChunks()
        for (metadata, fileURL) in pending {
            await ingestChunk(metadata: metadata, fileURL: fileURL)
        }
    }

    private func ingestChunk(metadata: AudioChunkMetadata, fileURL: URL) async {
        guard !ingestingChunkIDs.contains(metadata.id) else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        ingestingChunkIDs.insert(metadata.id)
        defer { ingestingChunkIDs.remove(metadata.id) }
        do {
            _ = try await coordinator.ingestLocalChunkFile(at: fileURL, metadata: metadata)
            diagnostics.emit(
                .transfer,
                name: "local-chunk-archived",
                payload: [
                    "chunkID": metadata.id.uuidString,
                    "sessionID": metadata.sessionID.uuidString,
                    "seq": "\(metadata.integrity.sequenceNumber)"
                ]
            )
        } catch {
            diagnostics.emit(
                .transfer,
                name: "local-ingest-failed",
                severity: .error,
                payload: [
                    "chunkID": metadata.id.uuidString,
                    "error": "\(error)"
                ]
            )
        }
    }
}

/// Late-bound chunk-finalization relay so `ChunkedCaptureService` can be
/// constructed before `PhoneCaptureService`'s actor-isolated handler binds.
private final class ChunkHandoffRelay: @unchecked Sendable {
    var handler: (@Sendable (AudioChunkMetadata, URL) async -> Void)?
    func call(_ metadata: AudioChunkMetadata, _ url: URL) async {
        await handler?(metadata, url)
    }
}
