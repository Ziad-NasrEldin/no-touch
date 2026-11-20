import Foundation

/// Language-tagged span inside a segment. BCP-47 codes (e.g. "ar-SA", "en")
/// with exact source timing so Arabic/English switching stays inspectable.
/// Offsets are UTF-16 code-unit indices into the owning segment's text.
public struct LanguageSpan: Codable, Sendable, Equatable, Hashable {
    public var languageCode: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var textRangeStart: Int
    public var textRangeEnd: Int

    public init(
        languageCode: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        textRangeStart: Int,
        textRangeEnd: Int
    ) {
        self.languageCode = languageCode
        self.startTime = startTime
        self.endTime = endTime
        self.textRangeStart = textRangeStart
        self.textRangeEnd = textRangeEnd
    }
}

public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var chunkID: UUID
    public var sessionID: UUID
    /// Seconds on the source chunk's media timeline; anchors audio playback.
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var wallStartTime: Date?
    public var text: String
    public var languageSpans: [LanguageSpan]
    public var confidence: Double?
    /// Diarized speaker label within the source chunk (0-based), nil when
    /// diarization did not run or could not attribute the segment.
    public var speakerID: Int?

    public init(
        id: UUID = UUID(),
        chunkID: UUID,
        sessionID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        wallStartTime: Date? = nil,
        text: String,
        languageSpans: [LanguageSpan] = [],
        confidence: Double? = nil,
        speakerID: Int? = nil
    ) {
        self.id = id
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.startTime = startTime
        self.endTime = endTime
        self.wallStartTime = wallStartTime
        self.text = text
        self.languageSpans = languageSpans
        self.confidence = confidence
        self.speakerID = speakerID
    }
}

/// Grounding link from generated output back to transcript + audio timing.
public struct SourcePassageReference: Codable, Sendable, Equatable, Hashable {
    public var segmentID: UUID
    public var chunkID: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var textRangeStart: Int?
    public var textRangeEnd: Int?

    public init(
        segmentID: UUID,
        chunkID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        textRangeStart: Int? = nil,
        textRangeEnd: Int? = nil
    ) {
        self.segmentID = segmentID
        self.chunkID = chunkID
        self.startTime = startTime
        self.endTime = endTime
        self.textRangeStart = textRangeStart
        self.textRangeEnd = textRangeEnd
    }
}

/// Group membership only; source segment timestamps are never rewritten.
/// Provisional groups may be updated by late-arriving chunks.
public struct ConversationGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var segmentIDs: [UUID]
    public var isProvisional: Bool
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        segmentIDs: [UUID],
        isProvisional: Bool = true,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.segmentIDs = segmentIDs
        self.isProvisional = isProvisional
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct DecisionItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var sources: [SourcePassageReference]

    public init(id: UUID = UUID(), text: String, sources: [SourcePassageReference] = []) {
        self.id = id
        self.text = text
        self.sources = sources
    }
}

/// Owner/due date stay nil unless the transcript explicitly supports them.
public struct ActionItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var owner: String?
    public var dueAt: Date?
    public var sources: [SourcePassageReference]

    public init(
        id: UUID = UUID(),
        text: String,
        owner: String? = nil,
        dueAt: Date? = nil,
        sources: [SourcePassageReference] = []
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.dueAt = dueAt
        self.sources = sources
    }
}

public struct GeneratedConversationMetadata: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var title: String?
    public var summary: String?
    public var suggestedCategory: String?
    public var decisions: [DecisionItem]
    public var actionItems: [ActionItem]
    public var sources: [SourcePassageReference]
    public var modelVersion: String
    public var generatedAt: Date

    public init(
        conversationID: UUID,
        title: String? = nil,
        summary: String? = nil,
        suggestedCategory: String? = nil,
        decisions: [DecisionItem] = [],
        actionItems: [ActionItem] = [],
        sources: [SourcePassageReference] = [],
        modelVersion: String,
        generatedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.title = title
        self.summary = summary
        self.suggestedCategory = suggestedCategory
        self.decisions = decisions
        self.actionItems = actionItems
        self.sources = sources
        self.modelVersion = modelVersion
        self.generatedAt = generatedAt
    }
}
