import Foundation
import RecorderContracts

public struct SpeechAdapterConfiguration: Sendable {
    /// Hard bound on one `transcribe` call's input. Chunks beyond this are
    /// rejected visibly (`inputExceedsBound`) rather than silently truncated.
    public var maxAudioSeconds: TimeInterval
    /// Engine PCM input rate; Whisper requires 16 kHz.
    public var targetSampleRate: Int
    /// Keep engine segments with empty text (VAD-only engines emit them as
    /// speech-activity evidence). Real engines rarely produce empty text.
    public var emitEmptySegments: Bool
    /// Skip chunks that contain no audible speech before acquiring
    /// `ModelExecutionGate` or loading WhisperKit.
    public var skipSilentChunks: Bool
    /// Minimum capture-reported speech seconds before trusting VAD silence.
    public var minimumSpeechSeconds: TimeInterval
    /// Peak 0.5 s window RMS below which a chunk is treated as silent.
    public var silentPeakWindowRMSThreshold: Float

    public init(
        maxAudioSeconds: TimeInterval = 300,
        targetSampleRate: Int = 16_000,
        emitEmptySegments: Bool = true,
        skipSilentChunks: Bool = true,
        minimumSpeechSeconds: TimeInterval = 0.5,
        silentPeakWindowRMSThreshold: Float = 0.003
    ) {
        self.maxAudioSeconds = maxAudioSeconds
        self.targetSampleRate = targetSampleRate
        self.emitEmptySegments = emitEmptySegments
        self.skipSilentChunks = skipSilentChunks
        self.minimumSpeechSeconds = minimumSpeechSeconds
        self.silentPeakWindowRMSThreshold = silentPeakWindowRMSThreshold
    }
}

/// `SpeechTranscriptionAdapterProtocol` over the engine seam.
///
/// Readiness flows from `ModelInstallController` (or `.ready` for model-free
/// engines); `transcribe` decodes the chunk under a hard size bound, holds
/// the shared `ModelExecutionGate` across load + inference so speech and text
/// models never co-resident spike memory, maps engine output into
/// `TranscriptSegment`s with exact chunk-relative timing and `ar`/`en`
/// `LanguageSpan`s, and stays cancellable + restartable per `AnalysisJob`.
public actor SpeechTranscriptionAdapter: SpeechTranscriptionAdapterProtocol, EngineBackedAdapter {
    public let engine: any SpeechTranscriptionEngine
    public nonisolated var engineIdentifier: String { engine.engineIdentifier }
    public nonisolated var engineModelVersion: String { engine.modelVersion }

    private let installController: ModelInstallController
    private let gate: ModelExecutionGate
    private let configuration: SpeechAdapterConfiguration
    private let diagnostics: @Sendable (DiagnosticsEvent) -> Void

    public init(
        engine: any SpeechTranscriptionEngine,
        installController: ModelInstallController,
        gate: ModelExecutionGate,
        configuration: SpeechAdapterConfiguration = .init(),
        diagnostics: @escaping @Sendable (DiagnosticsEvent) -> Void = { _ in }
    ) {
        self.engine = engine
        self.installController = installController
        self.gate = gate
        self.configuration = configuration
        self.diagnostics = diagnostics
    }

    // MARK: - Protocol surface

    public func readiness() async -> ModelReadinessState {
        guard engine.requiresModelInstall else { return .ready }
        return await installController.snapshot().state
    }

    public func transcribe(
        audioFileURL: URL,
        chunk: AudioChunkMetadata
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()

        let targetRate = configuration.targetSampleRate
        let maxSeconds = configuration.maxAudioSeconds
        let decoded = try await Task.detached(priority: .utility) {
            try AudioChunkDecoder.decode(
                fileAt: audioFileURL,
                targetSampleRate: targetRate,
                maxSeconds: maxSeconds
            )
        }.value
        guard !decoded.samples.isEmpty else { return [] }

        if configuration.skipSilentChunks {
            let peakRMS = Self.peakWindowRMS(samples: decoded.samples, sampleRate: decoded.sampleRate)
            let vadSpeech = chunk.integrity.voiceActivity?.speechSeconds
            let vadSilence = chunk.integrity.voiceActivity?.silenceSeconds ?? 0
            let vadSaysSilent = vadSpeech.map {
                $0 < configuration.minimumSpeechSeconds && (vadSilence > 0 || $0 == 0)
            } ?? false
            let isSilent = peakRMS < configuration.silentPeakWindowRMSThreshold
                || (vadSaysSilent && peakRMS < configuration.silentPeakWindowRMSThreshold * 2)
            if isSilent {
                diagnostics(DiagnosticsEvent(
                    subsystem: .ai,
                    name: "transcription.skipped_silent",
                    payload: [
                        "engine": engine.engineIdentifier,
                        "chunkID": chunk.id.uuidString,
                        "audioSeconds": String(format: "%.1f", decoded.duration),
                        "peakRMS": String(format: "%.5f", peakRMS),
                    ]
                ))
                return []
            }
        }

        let installedDirectory = try await readyInstallDirectory()
        let engine = self.engine
        let result = try await gate.withExclusiveAccess {
            try await engine.load(installedAt: installedDirectory)
            return try await engine.transcribe(
                samples: decoded.samples,
                sampleRate: decoded.sampleRate,
                mediaTimeOffset: 0
            )
        }
        try Task.checkCancellation()

        let segments = map(
            result: result,
            chunk: chunk,
            audioDuration: decoded.duration
        )
        diagnostics(DiagnosticsEvent(
            subsystem: .ai,
            name: "transcription.completed",
            payload: [
                "engine": engine.engineIdentifier,
                "chunkID": chunk.id.uuidString,
                "segments": "\(segments.count)",
                "audioSeconds": String(format: "%.1f", decoded.duration),
            ]
        ))
        return segments
    }

    // MARK: - Memory surface (phase-boundary seams only)

    /// Releases the engine's model resources so the other lane can use the
    /// memory (R1-4). Runs under the shared `ModelExecutionGate`, so the
    /// unload can never overlap in-flight inference on either engine; a
    /// cancelled caller simply skips the release. The engine lazily
    /// reloads on its next `load` — adapters already load inside the gate
    /// on every job. Call only at pipeline phase boundaries or on memory
    /// pressure — never from inside gate work (the gate is not reentrant).
    public func unloadEngine() async {
        let engine = self.engine
        try? await gate.withExclusiveAccess {
            await engine.unload()
        }
    }

    // MARK: - Install-flow surface (user-visible hooks only)

    /// The ONLY sanctioned download trigger. Wire to an explicit user action.
    public func installModel() async throws {
        try await installController.install()
    }

    public func cancelInstall() async {
        await installController.cancelInstall()
    }

    /// Progress/state stream for the install UX.
    public func installSnapshots() async -> AsyncStream<ModelInstallSnapshot> {
        await installController.snapshots()
    }

    public func installSnapshot() async -> ModelInstallSnapshot {
        await installController.snapshot()
    }

    // MARK: - Internals

    private func readyInstallDirectory() async throws -> URL? {
        guard engine.requiresModelInstall else { return nil }
        guard let directory = await installController.resolvedInstallDirectory() else {
            throw RecorderError.modelNotReady
        }
        return directory
    }

    /// Cheap peak 0.5 s window RMS across decoded mono Float32 PCM samples.
    /// Using a short window rather than a whole-chunk average preserves brief
    /// utterances inside an otherwise quiet 60 s clip while still rejecting
    /// pure silence / noise-floor chunks before loading WhisperKit.
    private static func peakWindowRMS(samples: [Float], sampleRate: Int) -> Float {
        guard !samples.isEmpty else { return 0 }
        let windowSize = max(1, sampleRate / 2)
        var maxMeanSquare: Float = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + windowSize, samples.count)
            var sumSq: Float = 0
            for i in offset..<end {
                let s = samples[i]
                sumSq += s * s
            }
            let meanSq = sumSq / Float(end - offset)
            if meanSq > maxMeanSquare {
                maxMeanSquare = meanSq
            }
            offset = end
        }
        return maxMeanSquare.squareRoot()
    }

    private func map(
        result: EngineTranscriptionResult,
        chunk: AudioChunkMetadata,
        audioDuration: TimeInterval
    ) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        output.reserveCapacity(result.segments.count)

        for engineSegment in result.segments {
            let trimmedText = engineSegment.text
            if !configuration.emitEmptySegments,
               trimmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                continue
            }

            let start = max(0, engineSegment.start)
            let end = min(max(start, engineSegment.end), audioDuration)
            let spans = LanguageSpanDeriver.spans(
                text: trimmedText,
                words: engineSegment.words,
                detectedLanguage: result.detectedLanguage,
                segmentStart: start,
                segmentEnd: end
            )
            let confidence = engineSegment.averageLogProbability.map {
                min(1, max(0, exp($0)))
            }
            output.append(TranscriptSegment(
                chunkID: chunk.id,
                sessionID: chunk.sessionID,
                startTime: start,
                endTime: end,
                wallStartTime: chunk.integrity.wallStartedAt.addingTimeInterval(start),
                text: trimmedText,
                languageSpans: spans,
                confidence: confidence,
                speakerID: engineSegment.speakerID
            ))
        }
        return output
    }
}
