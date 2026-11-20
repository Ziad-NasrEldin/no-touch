import AudioCapture
import Foundation
import RecorderContracts

/// Watch-side implementation of `WatchCaptureServiceProtocol`, backed by the
/// shared `ChunkedCaptureService` core and forwarding finalized chunks into
/// `WatchTransferServiceProtocol`.
public actor WatchCaptureService: WatchCaptureServiceProtocol {
    public static let defaultChunkDuration: TimeInterval = ChunkedCaptureService.defaultChunkDuration

    private let core: ChunkedCaptureService

    public init(
        outbox: (any WatchTransferServiceProtocol)? = nil,
        diagnostics: WatchDiagnostics? = nil,
        directory: URL? = nil,
        chunkDuration: TimeInterval = WatchCaptureService.defaultChunkDuration
    ) {
        let resolvedDiagnostics: CaptureDiagnostics
        if let diagnostics {
            resolvedDiagnostics = diagnostics
        } else if let directory {
            resolvedDiagnostics = CaptureDiagnostics(directory: directory, defaultFolderName: "WatchCapture")
        } else {
            resolvedDiagnostics = CaptureDiagnostics(defaultFolderName: "WatchCapture")
        }
        let handoff: (@Sendable (AudioChunkMetadata, URL) async -> Void)?
        if let outbox {
            handoff = { metadata, _ in
                do {
                    try await outbox.enqueueForTransfer(metadata)
                } catch {
                    resolvedDiagnostics.emit(
                        .transfer,
                        name: "enqueue-failed",
                        severity: .error,
                        payload: ["chunkID": metadata.id.uuidString, "error": "\(error)"]
                    )
                }
            }
        } else {
            handoff = nil
        }
        self.core = ChunkedCaptureService(
            defaultFolderName: "WatchCapture",
            directory: directory,
            diagnostics: resolvedDiagnostics,
            chunkDuration: chunkDuration,
            onChunkFinalized: handoff
        )
    }

    public func startSession() async throws -> RecordingSession {
        try await core.startSession()
    }

    public func pauseSession() async throws -> RecordingSession {
        try await core.pauseSession()
    }

    public func resumeSession() async throws -> RecordingSession {
        try await core.resumeSession()
    }

    public func stopSession() async throws -> RecordingSession {
        try await core.stopSession()
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

    public func appDidBecomeActive() async {
        await core.appDidBecomeActive()
    }

    public func appWillResignActive() async {
        await core.appWillResignActive()
    }

    public func appDidEnterBackground() async {
        await core.appDidEnterBackground()
    }
}
