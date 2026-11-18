import Foundation

public enum AnalysisJobKind: String, Codable, Sendable {
    case transcription
    case intelligence
}

public enum AnalysisJobState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

/// Durable, resumable unit of local AI work. Bounded (one chunk or one
/// conversation window) so retries never duplicate results.
public struct AnalysisJob: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: AnalysisJobKind
    public var state: AnalysisJobState
    public var chunkID: UUID?
    public var conversationID: UUID?
    public var attemptCount: Int
    public var lastError: String?
    public var modelVersion: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: AnalysisJobKind,
        state: AnalysisJobState = .queued,
        chunkID: UUID? = nil,
        conversationID: UUID? = nil,
        attemptCount: Int = 0,
        lastError: String? = nil,
        modelVersion: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.chunkID = chunkID
        self.conversationID = conversationID
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.modelVersion = modelVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ModelReadinessState: String, Codable, Sendable {
    case notInstalled
    case downloading
    case verifying
    case ready
    case failed
}
