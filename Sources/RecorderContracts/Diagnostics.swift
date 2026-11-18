import Foundation

public enum DiagnosticsSubsystem: String, Codable, Sendable, CaseIterable {
    case capture
    case transfer
    case storage
    case ai
    case lifecycle
}

public enum DiagnosticsSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

/// Structured evidence for Gate A measurements. Payloads carry counts, states,
/// timings, and error classes only — never audio content or transcript text.
public struct DiagnosticsEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var subsystem: DiagnosticsSubsystem
    public var severity: DiagnosticsSeverity
    public var name: String
    public var payload: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        subsystem: DiagnosticsSubsystem,
        severity: DiagnosticsSeverity = .info,
        name: String,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.severity = severity
        self.name = name
        self.payload = payload
    }
}

public struct DiagnosticsReport: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var deviceModel: String
    public var osVersion: String
    public var events: [DiagnosticsEvent]

    public init(
        generatedAt: Date = Date(),
        deviceModel: String,
        osVersion: String,
        events: [DiagnosticsEvent]
    ) {
        self.generatedAt = generatedAt
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.events = events
    }
}
