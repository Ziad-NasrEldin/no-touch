import Foundation

/// Deterministic, model-free speech engine: energy-VAD segmentation only.
/// Same input always produces the same output, which makes it suitable for
/// manually exercising the adapter pipeline (decode → window → segment map →
/// timing) without a model. It never invents transcript text — emitted
/// segments carry empty `text` and nil confidence, marking speech-activity
/// intervals only. It is never auto-selected over a real engine; callers must
/// opt in explicitly.
public actor DeterministicSpeechEngine: SpeechTranscriptionEngine {
    public let engineIdentifier = "vad-v1"
    public let modelVersion = "deterministic-vad-1"
    public let requiresModelInstall = false

    /// RMS-energy threshold above the file's noise floor for a frame to count
    /// as speech. Values are linear amplitude.
    private let frameSeconds: Double = 0.03
    private let thresholdAboveFloor: Float = 0.015
    private let absoluteThreshold: Float = 0.004
    private let minSegmentSeconds: Double = 0.25
    private let mergeGapSeconds: Double = 0.5
    private let hangoverSeconds: Double = 0.3

    public init() {}

    public func load(installedAt directory: URL?) async throws {}
    public func unload() async {}

    public func transcribe(
        samples: [Float],
        sampleRate: Int,
        mediaTimeOffset: TimeInterval
    ) async throws -> EngineTranscriptionResult {
        try Task.checkCancellation()
        guard sampleRate > 0, !samples.isEmpty else {
            return EngineTranscriptionResult(detectedLanguage: nil, segments: [])
        }

        let frame = max(1, Int(frameSeconds * Double(sampleRate)))
        var rms: [Float] = []
        rms.reserveCapacity(samples.count / frame + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + frame, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            rms.append((sum / Float(end - index)).squareRoot())
            index = end
        }

        // Noise floor = 20th-percentile frame energy; threshold sits above it.
        let sorted = rms.sorted()
        let floorValue = sorted.isEmpty ? 0 : sorted[max(0, Int(Double(sorted.count) * 0.2) - 1)]
        let threshold = max(absoluteThreshold, floorValue + thresholdAboveFloor)

        // Mark speech frames, apply hangover, then merge runs.
        let hangoverFrames = max(1, Int(hangoverSeconds / frameSeconds))
        var runs: [(start: TimeInterval, end: TimeInterval)] = []
        var runStart: TimeInterval?
        var lastActiveFrame = -hangoverFrames - 1
        for i in rms.indices {
            if rms[i] >= threshold {
                if runStart == nil && i - lastActiveFrame > hangoverFrames {
                    runStart = Double(i) * frameSeconds
                }
                lastActiveFrame = i
            } else if runStart != nil, i - lastActiveFrame > hangoverFrames {
                let start = Double(max(0, lastActiveFrame - hangoverFrames + 1)) * frameSeconds
                runs.append((runStart ?? start, Double(lastActiveFrame + 1) * frameSeconds))
                runStart = nil
            }
        }
        if let runStart {
            runs.append((runStart, Double(lastActiveFrame + 1) * frameSeconds))
        }

        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        for run in runs where run.end - run.start >= minSegmentSeconds {
            if let last = merged.last, run.start - last.end <= mergeGapSeconds {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }

        let segments = merged.map {
            EngineTranscriptSegment(
                start: $0.start + mediaTimeOffset,
                end: min($0.end + mediaTimeOffset, mediaTimeOffset + Double(samples.count) / Double(sampleRate)),
                text: ""
            )
        }
        return EngineTranscriptionResult(detectedLanguage: nil, segments: segments)
    }
}

/// Deterministic text engine for manual pipeline exercise. Reads the rendered
/// `[S<n>]` transcript lines out of `userPrompt` and emits schema-valid JSON
/// built extractively (first lines → title/summary, category "أخرى", no
/// decisions or action items). It never fabricates content beyond the
/// transcript text and never claims model quality — `modelVersion` says so.
public actor HeuristicTextEngine: TextIntelligenceEngine {
    public let engineIdentifier = "heuristic-v1"
    public let modelVersion = "deterministic-extractive-1"
    public let requiresModelInstall = false

    public init() {}

    public func load(installedAt directory: URL?) async throws {}
    public func unload() async {}

    public func complete(_ request: TextCompletionRequest) async throws -> TextCompletionResult {
        try Task.checkCancellation()
        // Extract "[S12] (1.2s-3.4s) text" lines the renderer wrote.
        let linePattern = #"\[S(\d+)\][^\n]*"#
        let regex = try NSRegularExpression(pattern: linePattern)
        let nsPrompt = request.userPrompt as NSString
        let matches = regex.matches(in: request.userPrompt, range: NSRange(location: 0, length: nsPrompt.length))

        var refs: [String] = []
        var texts: [String] = []
        for match in matches.prefix(4) {
            let line = nsPrompt.substring(with: match.range)
            refs.append("S" + nsPrompt.substring(with: match.range(at: 1)))
            if let range = line.range(of: ") ") {
                texts.append(String(line[range.upperBound...]))
            }
        }
        let transcriptEmpty = texts.joined().trimmingCharacters(in: .whitespaces).isEmpty

        struct Output: Encodable {
            var title: String?
            var title_refs: [String]
            var summary: String?
            var summary_refs: [String]
            var category: String?
            var decisions: [String] = []
            var action_items: [String] = []
        }
        let output = Output(
            title: transcriptEmpty ? nil : texts.first.map { String($0.prefix(60)) },
            title_refs: transcriptEmpty ? [] : refs.prefix(1).map { $0 },
            summary: transcriptEmpty ? nil : texts.joined(separator: " … ").prefix(280).description,
            summary_refs: transcriptEmpty ? [] : refs,
            category: transcriptEmpty ? nil : "أخرى"
        )
        let data = try JSONEncoder().encode(output)
        return TextCompletionResult(text: String(decoding: data, as: UTF8.self))
    }
}
