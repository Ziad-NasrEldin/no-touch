import Foundation

/// Observable lifecycle of a day-long capture session. `recording` is reported
/// only while capture is actually active.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case idle
    case recording
    case paused
    case interrupted
    case stopped
}

public enum FailureReason: String, Codable, Sendable {
    case microphoneDenied
    case lowStorage
    case lowBattery
    case audioSessionInterrupted
    case unrecoverableTermination
    case unknown
}

/// A gap in confirmed capture. An interval with no confirmed audio is missing,
/// never implied silence.
public struct InterruptionInterval: Codable, Sendable, Equatable, Hashable {
    public var beganAt: Date
    public var endedAt: Date?
    public var reason: FailureReason

    public init(beganAt: Date, endedAt: Date? = nil, reason: FailureReason) {
        self.beganAt = beganAt
        self.endedAt = endedAt
        self.reason = reason
    }
}

public struct RecordingSession: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var state: SessionState
    public var failureReason: FailureReason?
    public var startedAt: Date?
    public var stoppedAt: Date?
    public var lastConfirmedCaptureAt: Date?
    public var interruptionIntervals: [InterruptionInterval]

    public init(
        id: UUID = UUID(),
        state: SessionState = .idle,
        failureReason: FailureReason? = nil,
        startedAt: Date? = nil,
        stoppedAt: Date? = nil,
        lastConfirmedCaptureAt: Date? = nil,
        interruptionIntervals: [InterruptionInterval] = []
    ) {
        self.id = id
        self.state = state
        self.failureReason = failureReason
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.lastConfirmedCaptureAt = lastConfirmedCaptureAt
        self.interruptionIntervals = interruptionIntervals
    }
}
