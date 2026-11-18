import Foundation

/// Encoding chosen by the capture worker after measured quality/endurance
/// trials; stored as data so the contract does not pick a codec early.
public struct AudioChunkFormat: Codable, Sendable, Equatable, Hashable {
    public var container: String
    public var codec: String
    public var sampleRate: Double
    public var channelCount: Int

    public init(container: String, codec: String, sampleRate: Double, channelCount: Int = 1) {
        self.container = container
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Optional VAD bookkeeping. Discarding silence reduces transfer/analysis work
/// but never discards timing knowledge: speech/silence seconds are preserved.
public struct VoiceActivitySummary: Codable, Sendable, Equatable, Hashable {
    public var speechSeconds: TimeInterval?
    public var silenceSeconds: TimeInterval?
    public var algorithmIdentifier: String?

    public init(
        speechSeconds: TimeInterval? = nil,
        silenceSeconds: TimeInterval? = nil,
        algorithmIdentifier: String? = nil
    ) {
        self.speechSeconds = speechSeconds
        self.silenceSeconds = silenceSeconds
        self.algorithmIdentifier = algorithmIdentifier
    }
}

/// Integrity + timing evidence for one finalized chunk. The phone verifies the
/// digest before acknowledging; wall timestamps anchor playback, monotonic
/// seconds order chunks across clock changes.
public struct ChunkIntegrity: Codable, Sendable, Equatable, Hashable {
    public var sha256Hex: String
    public var byteCount: Int
    public var duration: TimeInterval
    public var sequenceNumber: Int
    public var monotonicStartSeconds: Double
    public var monotonicEndSeconds: Double
    public var wallStartedAt: Date
    public var wallEndedAt: Date
    public var voiceActivity: VoiceActivitySummary?

    public init(
        sha256Hex: String,
        byteCount: Int,
        duration: TimeInterval,
        sequenceNumber: Int,
        monotonicStartSeconds: Double,
        monotonicEndSeconds: Double,
        wallStartedAt: Date,
        wallEndedAt: Date,
        voiceActivity: VoiceActivitySummary? = nil
    ) {
        self.sha256Hex = sha256Hex
        self.byteCount = byteCount
        self.duration = duration
        self.sequenceNumber = sequenceNumber
        self.monotonicStartSeconds = monotonicStartSeconds
        self.monotonicEndSeconds = monotonicEndSeconds
        self.wallStartedAt = wallStartedAt
        self.wallEndedAt = wallEndedAt
        self.voiceActivity = voiceActivity
    }
}

public struct AudioChunkMetadata: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var sessionID: UUID
    public var fileName: String
    public var format: AudioChunkFormat
    public var integrity: ChunkIntegrity

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        fileName: String,
        format: AudioChunkFormat,
        integrity: ChunkIntegrity
    ) {
        self.id = id
        self.sessionID = sessionID
        self.fileName = fileName
        self.format = format
        self.integrity = integrity
    }
}
