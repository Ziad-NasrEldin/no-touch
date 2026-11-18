import Foundation

/// A persistent user edit. Reprocessing must never silently overwrite fields
/// covered by an override record.
public struct UserOverrideRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Field: String, Codable, Sendable {
        case title
        case category
        case summary
    }

    public var id: UUID
    public var conversationID: UUID
    public var field: Field
    public var value: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        field: Field,
        value: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.field = field
        self.value = value
        self.createdAt = createdAt
    }
}

/// Persisted deletion so delayed transfers, retries, or late chunks cannot
/// resurrect deleted content. `propagatedToWatch` tracks remote cleanup.
public struct DeletionIntent: Codable, Sendable, Equatable, Identifiable {
    public enum Target: String, Codable, Sendable {
        case conversation
        case chunk
        case session
    }

    public var id: UUID
    public var target: Target
    public var targetID: UUID
    public var createdAt: Date
    public var propagatedToWatch: Bool

    public init(
        id: UUID = UUID(),
        target: Target,
        targetID: UUID,
        createdAt: Date = Date(),
        propagatedToWatch: Bool = false
    ) {
        self.id = id
        self.target = target
        self.targetID = targetID
        self.createdAt = createdAt
        self.propagatedToWatch = propagatedToWatch
    }
}

/// Raw-audio retention. Expired audio keeps transcripts; playback becomes
/// unavailable rather than silently gone.
public struct RetentionPolicy: Codable, Sendable, Equatable {
    /// Days raw audio is kept; nil keeps it until explicit deletion.
    public var keepAudioDays: Int?
    public var deleteAudioAfterTranscription: Bool

    public init(keepAudioDays: Int? = nil, deleteAudioAfterTranscription: Bool = false) {
        self.keepAudioDays = keepAudioDays
        self.deleteAudioAfterTranscription = deleteAudioAfterTranscription
    }
}

public enum AudioAvailabilityState: String, Codable, Sendable {
    case pending
    case available
    case expired
    case deleted
}
