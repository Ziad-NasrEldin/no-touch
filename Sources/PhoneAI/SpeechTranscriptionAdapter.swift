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

    public init(
        maxAudioSeconds: TimeInterval = 300,
        targetSampleRate: Int = 16_000,
        emitEmptySegments: Bool = true
    ) {
        self.maxAudioSeconds = maxAudioSeconds
        self.targetSampleRate = targetSampleRate
        self.emitEmptySegments = emitEmptySegments
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

        let decoded = try AudioChunkDecoder.decode(
            fileAt: audioFileURL,
            targetSampleRate: configuration.targetSampleRate,
            maxSeconds: configuration.maxAudioSeconds
        )
        guard !decoded.samples.isEmpty else { return [] }

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
        let snapshot = await installController.snapshot()
        guard snapshot.state == .ready, let path = snapshot.installDirectory else {
            throw RecorderError.modelNotReady
        }
        return URL(fileURLWithPath: path, isDirectory: true)
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
                confidence: confidence
            ))
        }
        return output
    }
}
