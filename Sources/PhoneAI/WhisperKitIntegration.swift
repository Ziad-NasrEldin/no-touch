import Foundation
import RecorderContracts

#if canImport(WhisperKit)
import WhisperKit
#if canImport(SpeakerKit)
import SpeakerKit
#endif

/// Real speech engine backed by Argmax WhisperKit (CoreML Whisper builds).
///
/// Compiled only when the `WhisperKit` product is registered on this target —
/// see handoff for the exact SPM registration I1 must apply. Hard rules this
/// engine keeps: `task: .transcribe` (never `.translate`), multilingual
/// variants only (the catalog never lists `.en` variants), per-window
/// language auto-detection (`detectLanguage: true`, `language: nil`), and
/// `wordTimestamps` so `LanguageSpanDeriver` can recover ar/en switching.
public actor WhisperKitSpeechEngine: SpeechTranscriptionEngine {
    public let engineIdentifier = "whisperkit"
    public let modelVersion: String
    public let requiresModelInstall = true

    private let variant: String
    private let descriptorID: String
    private var pipe: WhisperKit?
    private var speakerModelsBase: URL?
    #if canImport(SpeakerKit)
    private var speakerKit: SpeakerKit?
    #endif

    public init(descriptor: ModelDescriptor) {
        guard case .whisperKitRepository(let variant, _) = descriptor.installMethod else {
            preconditionFailure("WhisperKitSpeechEngine requires a whisperKitRepository descriptor")
        }
        self.variant = variant
        self.descriptorID = descriptor.id
        self.modelVersion = descriptor.modelVersion
    }

    public func load(installedAt directory: URL?) async throws {
        if pipe != nil { return }
        guard let directory else {
            throw RecorderError.modelNotReady
        }
        // download: false — inference is fully offline after the install flow
        // delivered the variant folder; this engine must never hit the network.
        let config = WhisperKitConfig(
            model: variant,
            modelFolder: directory.path,
            // Neural Engine + CPU only: iOS forbids GPU work from background
            // apps, and the ANE is both fast and allowed while backgrounded,
            // so clips transcribe live as they arrive from the watch.
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndNeuralEngine,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
        // Speaker models live next to the speech model install.
        speakerModelsBase = directory.deletingLastPathComponent().appendingPathComponent("speakerkit", isDirectory: true)
    }

    public func unload() async {
        if let pipe {
            await pipe.unloadModels()
        }
        pipe = nil
        #if canImport(SpeakerKit)
        if let speakerKit { await speakerKit.unloadModels() }
        speakerKit = nil
        #endif
    }

    public func transcribe(
        samples: [Float],
        sampleRate: Int,
        mediaTimeOffset: TimeInterval
    ) async throws -> EngineTranscriptionResult {
        try Task.checkCancellation()
        guard sampleRate == 16_000, !samples.isEmpty else {
            return EngineTranscriptionResult(detectedLanguage: nil, segments: [])
        }
        guard let pipe else {
            throw RecorderError.modelNotReady
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            detectLanguage: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()

        var engineSegments: [EngineTranscriptSegment] = []
        var detected: String?
        var detectedCount: [String: Int] = [:]
        for result in results {
            if !result.language.isEmpty {
                detectedCount[result.language, default: 0] += result.segments.count
            }
            for segment in result.segments {
                let words = segment.words?.map {
                    EngineWord(
                        text: $0.word,
                        start: TimeInterval($0.start) + mediaTimeOffset,
                        end: TimeInterval($0.end) + mediaTimeOffset,
                        probability: Double($0.probability)
                    )
                }
                engineSegments.append(EngineTranscriptSegment(
                    start: TimeInterval(segment.start) + mediaTimeOffset,
                    end: TimeInterval(segment.end) + mediaTimeOffset,
                    text: Self.stripSpecialTokens(segment.text),
                    averageLogProbability: Double(segment.avgLogprob),
                    noSpeechProbability: Double(segment.noSpeechProb),
                    words: words
                ))
            }
        }
        detected = detectedCount.max(by: { $0.value < $1.value })?.key
        engineSegments.sort { $0.start < $1.start }
        if !engineSegments.isEmpty {
            await assignSpeakers(to: &engineSegments, samples: samples, mediaTimeOffset: mediaTimeOffset)
        }
        return EngineTranscriptionResult(detectedLanguage: detected, segments: engineSegments)
    }

    /// Diarizes the same audio with SpeakerKit (pyannote, on-device) and
    /// labels each transcript segment with the speaker that overlaps it most.
    /// Best effort: any failure (e.g. speaker models not downloadable yet)
    /// leaves segments unlabeled instead of failing the transcription.
    private func assignSpeakers(
        to segments: inout [EngineTranscriptSegment],
        samples: [Float],
        mediaTimeOffset: TimeInterval
    ) async {
        #if canImport(SpeakerKit)
        do {
            if speakerKit == nil {
                if let base = speakerModelsBase {
                    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                }
                speakerKit = try await SpeakerKit(PyannoteConfig(
                    downloadBase: speakerModelsBase?.path,
                    download: true,
                    load: true,
                    verbose: false,
                    logLevel: .error
                ))
            }
            guard let speakerKit else { return }
            let result = try await speakerKit.diarize(audioArray: samples)
            let turns: [(id: Int, start: TimeInterval, end: TimeInterval)] = result.segments.compactMap { turn in
                guard let id = turn.speaker.speakerId else { return nil }
                return (id, TimeInterval(turn.startTime) + mediaTimeOffset, TimeInterval(turn.endTime) + mediaTimeOffset)
            }
            guard !turns.isEmpty else { return }
            for index in segments.indices {
                let seg = segments[index]
                var overlapBySpeaker: [Int: TimeInterval] = [:]
                for turn in turns {
                    let overlap = min(seg.end, turn.end) - max(seg.start, turn.start)
                    if overlap > 0 { overlapBySpeaker[turn.id, default: 0] += overlap }
                }
                if let best = overlapBySpeaker.max(by: { $0.value < $1.value })?.key {
                    segments[index].speakerID = best
                } else {
                    // No overlap: take the nearest turn.
                    let mid = (seg.start + seg.end) / 2
                    segments[index].speakerID = turns.min(by: {
                        abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid)
                    })?.id
                }
            }
        } catch {
            // Diarization is optional; keep the transcript.
        }
        #endif
    }

    /// WhisperKit segment text can carry decoder control tokens like
    /// startoftranscript, language ids, and timestamp markers in pipe-bracket
    /// form. They are decoder markup, not speech, so strip them before the
    /// text is stored or indexed by language spans.
    private static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }
}

/// WhisperKit repository downloader. Wraps `WhisperKit.download` so the
/// install state machine owns progress/verification while the package owns
/// Hugging Face snapshot layout and resume. `downloadBase` points the hub
/// cache inside the app-owned model directory so bytes land where the store
/// expects them.
public struct WhisperKitModelDownloader: ModelContentDownloader {
    public init() {}

    public func download(
        descriptor: ModelDescriptor,
        into directory: URL,
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws -> URL {
        guard case .whisperKitRepository(let variant, let repo) = descriptor.installMethod else {
            throw PhoneAIError.unsupportedInstallMethod("WhisperKitModelDownloader only handles .whisperKitRepository")
        }
        let expected = descriptor.expectedBytes
        let resolved = try await WhisperKit.download(
            variant: variant,
            downloadBase: directory,
            from: repo,
            progressCallback: { p in
                if let expected, expected > 0 {
                    progress(Int64(p.fractionCompleted * Double(expected)), expected)
                } else {
                    progress(p.completedUnitCount, p.totalUnitCount > 0 ? p.totalUnitCount : nil)
                }
            }
        )
        return resolved
    }

    public func verify(descriptor: ModelDescriptor, installedAt directory: URL) async -> Bool {
        let fm = FileManager.default
        var sawCompiledModel = false
        var sawConfig = false
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return false }
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "mlmodelc" { sawCompiledModel = true }
            if url.lastPathComponent == "config.json" { sawConfig = true }
        }
        return sawCompiledModel && sawConfig
    }
}
#endif
