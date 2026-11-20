import Foundation
import RecorderContracts

/// Wiring helpers for the PhoneAI lane — keeps every engine seam,
/// install-controller, and gate decision in one place so integration stays
/// honest about which backend actually bound.
public enum PhoneAI {

    /// App-owned, backup-excluded models root:
    /// `Application Support/PhoneAI/Models`. Created on demand; raw model
    /// bytes never enter iCloud backup.
    public static func modelsRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var root = base.appendingPathComponent("PhoneAI/Models", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root
    }

    /// Default speech adapter for `descriptor`.
    ///
    /// Engine selection: a `WhisperKitSpeechEngine` binds whenever the
    /// WhisperKit product is compiled into this target and the descriptor's
    /// method is `.whisperKitRepository`; otherwise the deterministic VAD
    /// engine binds (engineIdentifier "vad-v1") so the pipeline stays
    /// exercisable. Callers should check `adapter.engineIdentifier` — with
    /// the real package registered it must read "whisperkit".
    public static func makeSpeechAdapter(
        descriptor: ModelDescriptor = PhoneAIModelCatalog.whisperLargeV3Turbo,
        modelsRoot: URL,
        gate: ModelExecutionGate = ModelExecutionGate(),
        engine: (any SpeechTranscriptionEngine)? = nil,
        configuration: SpeechAdapterConfiguration = .init(),
        diagnostics: @escaping @Sendable (DiagnosticsEvent) -> Void = { _ in }
    ) throws -> SpeechTranscriptionAdapter {
        let controller = try ModelInstallController(descriptor: descriptor, rootDirectory: modelsRoot)
        let bound = engine ?? defaultSpeechEngine(descriptor: descriptor)
        return SpeechTranscriptionAdapter(
            engine: bound,
            installController: controller,
            gate: gate,
            configuration: configuration,
            diagnostics: diagnostics
        )
    }

    /// Default text-intelligence adapter for `descriptor`.
    /// Binds `MLXChatTextEngine` when MLX products are compiled in and the
    /// descriptor is `.mlxRepository`; otherwise `HeuristicTextEngine`
    /// ("heuristic-v1").
    public static func makeTextAdapter(
        descriptor: ModelDescriptor = PhoneAIModelCatalog.qwen3_1_7b_4bit,
        modelsRoot: URL,
        gate: ModelExecutionGate = ModelExecutionGate(),
        engine: (any TextIntelligenceEngine)? = nil,
        configuration: TextIntelligenceConfiguration = .init(),
        diagnostics: @escaping @Sendable (DiagnosticsEvent) -> Void = { _ in }
    ) throws -> TextIntelligenceAdapter {
        let controller = try ModelInstallController(descriptor: descriptor, rootDirectory: modelsRoot)
        let bound = engine ?? defaultTextEngine(descriptor: descriptor)
        return TextIntelligenceAdapter(
            engine: bound,
            installController: controller,
            gate: gate,
            configuration: configuration,
            diagnostics: diagnostics
        )
    }

    private static func defaultSpeechEngine(descriptor: ModelDescriptor) -> any SpeechTranscriptionEngine {
        #if canImport(WhisperKit)
        if case .whisperKitRepository = descriptor.installMethod {
            return WhisperKitSpeechEngine(descriptor: descriptor)
        }
        #endif
        return DeterministicSpeechEngine()
    }

    private static func defaultTextEngine(descriptor: ModelDescriptor) -> any TextIntelligenceEngine {
        // MLX's C++ Metal device initializer aborts (SIGABRT) on iOS Simulator
        // because the simulator lacks MLX's Metal runtime; keep real MLX on
        // physical Apple Silicon devices and fall back honestly to the
        // deterministic extractive engine on simulator.
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && !targetEnvironment(simulator)
        if case .mlxRepository = descriptor.installMethod {
            return MLXChatTextEngine(descriptor: descriptor)
        }
        #endif
        return HeuristicTextEngine()
    }
}
