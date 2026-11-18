import Foundation
import RecorderContracts

/// Phase 0 placeholder for C1. Tracks session state transitions in memory so
/// the watch UI can compile and bind; performs no microphone capture, no file
/// writes, and no background-audio work yet.
public actor PlaceholderCaptureService: WatchCaptureServiceProtocol {
    private var session: RecordingSession?
    private var chunks: [UUID: [AudioChunkMetadata]] = [:]

    public init() {}

    public func startSession() async throws -> RecordingSession {
        if var existing = session, existing.state == .paused || existing.state == .interrupted {
            existing.state = .recording
            session = existing
            return existing
        }
        let started = RecordingSession(state: .recording, startedAt: Date())
        session = started
        return started
    }

    public func pauseSession() async throws -> RecordingSession {
        try transition(to: .paused, allowedFrom: [.recording])
    }

    public func resumeSession() async throws -> RecordingSession {
        try transition(to: .recording, allowedFrom: [.paused])
    }

    public func stopSession() async throws -> RecordingSession {
        guard var current = session, current.state != .idle, current.state != .stopped else {
            throw RecorderError.invalidState(session?.state ?? .idle)
        }
        current.state = .stopped
        current.stoppedAt = Date()
        session = current
        return current
    }

    public func currentSession() async -> RecordingSession? {
        session
    }

    public func finalizedChunks(sessionID: UUID) async -> [AudioChunkMetadata] {
        chunks[sessionID] ?? []
    }

    public nonisolated func stateUpdates() -> AsyncStream<RecordingSession> {
        // C1 replaces this with a live stream backed by capture state.
        AsyncStream { continuation in continuation.finish() }
    }

    private func transition(to next: SessionState, allowedFrom states: [SessionState]) throws -> RecordingSession {
        guard var current = session, states.contains(current.state) else {
            throw RecorderError.invalidState(session?.state ?? .idle)
        }
        current.state = next
        session = current
        return current
    }
}
