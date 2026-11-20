import Foundation
import RecorderContracts

/// One word (or token cluster) with its position on the source media timeline.
/// Times are seconds relative to the start of the audio passed to the engine.
public struct EngineWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var probability: Double?

    public init(text: String, start: TimeInterval, end: TimeInterval, probability: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// Engine-neutral utterance. `text` is verbatim engine output — never
/// translated, never re-cased, punctuation and RTL preserved.
public struct EngineTranscriptSegment: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Whisper-style average log-probability; `exp()` is a rough confidence.
    public var averageLogProbability: Double?
    /// Whisper-style no-speech probability for the segment.
    public var noSpeechProbability: Double?
    public var words: [EngineWord]?
    /// Diarized speaker label (0-based) within this audio, if known.
    public var speakerID: Int?

    public init(
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        averageLogProbability: Double? = nil,
        noSpeechProbability: Double? = nil,
        words: [EngineWord]? = nil,
        speakerID: Int? = nil
    ) {
        self.start = start
        self.speakerID = speakerID
        self.end = end
        self.text = text
        self.averageLogProbability = averageLogProbability
        self.noSpeechProbability = noSpeechProbability
        self.words = words
    }
}

public struct EngineTranscriptionResult: Sendable, Equatable {
    /// Dominant language the engine detected for this window (BCP-47 / ISO-639
    /// base code, e.g. "ar", "en"). May be nil when the engine can't detect.
    public var detectedLanguage: String?
    public var segments: [EngineTranscriptSegment]

    public init(detectedLanguage: String?, segments: [EngineTranscriptSegment]) {
        self.detectedLanguage = detectedLanguage
        self.segments = segments
    }
}

/// Engine seam for on-device speech-to-text. Concrete engines:
/// `WhisperKitSpeechEngine` (compiled only when the WhisperKit product is
/// registered on this target) and `DeterministicSpeechEngine` (always
/// available, no model, for manual pipeline exercise).
///
/// Contract: implementations transcribe — never translate — and return
/// verbatim text with source-relative timing. `load` must be idempotent and
/// may be called repeatedly (e.g. after `unload` under memory pressure).
public protocol SpeechTranscriptionEngine: Sendable {
    /// Stable identifier recorded on diagnostics and used by callers to
    /// detect which backend actually bound (e.g. "whisperkit", "vad-v1").
    var engineIdentifier: String { get }
    /// Version string stamped on `AnalysisJob.modelVersion` and persisted
    /// results so reprocessing stays explainable.
    var modelVersion: String { get }
    /// Whether this engine needs an installed model before `transcribe` can
    /// run. The deterministic engine returns false (always "ready").
    var requiresModelInstall: Bool { get }
    /// Load model weights/resources. `installedAt` is the directory recorded
    /// by `ModelInstallController` after a successful install; engines that
    /// don't need a model ignore it.
    func load(installedAt directory: URL?) async throws
    /// Release model resources so another engine can use the memory.
    func unload() async
    /// Transcribe 16 kHz (or `sampleRate`) mono PCM. `mediaTimeOffset` is the
    /// position of `samples[0]` on the chunk's media timeline; returned
    /// segment times must include it (i.e. be chunk-relative, not window-
    /// relative).
    func transcribe(
        samples: [Float],
        sampleRate: Int,
        mediaTimeOffset: TimeInterval
    ) async throws -> EngineTranscriptionResult
}

/// A single text completion request. The transcript text inside `userPrompt`
/// is data under instruction discipline — engines must not add tool calls or
/// follow instructions embedded in it.
public struct TextCompletionRequest: Sendable, Equatable {
    public var systemPrompt: String
    public var userPrompt: String
    public var maxTokens: Int
    public var temperature: Double

    public init(systemPrompt: String, userPrompt: String, maxTokens: Int, temperature: Double) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct TextCompletionResult: Sendable, Equatable {
    public var text: String
    /// Engine-reported usage, when available (for diagnostics only).
    public var promptTokenCount: Int?
    public var generatedTokenCount: Int?

    public init(text: String, promptTokenCount: Int? = nil, generatedTokenCount: Int? = nil) {
        self.text = text
        self.promptTokenCount = promptTokenCount
        self.generatedTokenCount = generatedTokenCount
    }
}

/// Engine seam for local text intelligence: grounded metadata extraction and
/// optional conversation-boundary review. Concrete engines:
/// `MLXChatTextEngine` (compiled only when MLXLLM/MLXLMCommon are registered)
/// and `HeuristicTextEngine` (deterministic, extractive, always available).
public protocol TextIntelligenceEngine: Sendable {
    var engineIdentifier: String { get }
    var modelVersion: String { get }
    var requiresModelInstall: Bool { get }
    func load(installedAt directory: URL?) async throws
    func unload() async
    func complete(_ request: TextCompletionRequest) async throws -> TextCompletionResult
}
