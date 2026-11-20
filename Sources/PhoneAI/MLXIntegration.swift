import Foundation
import RecorderContracts

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import Hub
#if canImport(MLX)
import MLX
#endif
import MLXLLM
import MLXLMCommon

/// Real text-intelligence engine backed by an MLX-format instruct model via
/// `mlx-swift-lm` (e.g. `mlx-community/Qwen3-1.7B-4bit`).
///
/// Compiled only when `MLXLLM` + `MLXLMCommon` are registered on this target.
/// The engine loads only from an installed directory (or the HF cache dir a
/// prior install produced) — it performs no network access itself.
public actor MLXChatTextEngine: TextIntelligenceEngine {
    public let engineIdentifier = "mlx-lm"
    public let modelVersion: String
    public let requiresModelInstall = true

    private let hubID: String
    private let revision: String
    private var container: ModelContainer?

    /// Bounds KV cache growth for a small on-device model.
    private let maxKVSize = 2_048
    /// Caps MLX's Metal buffer cache on 6 GB iOS devices.
    private static let metalCacheLimitBytes = 20 * 1024 * 1024

    public init(descriptor: ModelDescriptor) {
        guard case .mlxRepository(let id, let revision) = descriptor.installMethod else {
            preconditionFailure("MLXChatTextEngine requires an mlxRepository descriptor")
        }
        self.hubID = id
        self.revision = revision
        self.modelVersion = descriptor.modelVersion
    }

    public func load(installedAt directory: URL?) async throws {
        if container != nil { return }
        #if targetEnvironment(simulator)
        throw PhoneAIError.unsupportedInstallMethod(
            "MLX Metal inference is unavailable on iOS Simulator — run on a physical Apple Silicon iPhone"
        )
        #else
        #if canImport(MLX)
        MLX.Memory.cacheLimit = Self.metalCacheLimitBytes
        #endif
        _ = LLMRegistry.shared // force MLXLLM trampoline registration
        if let directory {
            container = try await loadModelContainer(directory: directory) { _ in }
        } else {
            // Standalone path (no install controller): loads from the default
            // HF cache; still fully offline once cached.
            container = try await loadModelContainer(id: hubID, revision: revision) { _ in }
        }
        #endif
    }

    public func unload() async {
        container = nil
        #if canImport(MLX) && !targetEnvironment(simulator)
        MLX.Memory.clearCache()
        #endif
    }

    public func complete(_ request: TextCompletionRequest) async throws -> TextCompletionResult {
        try Task.checkCancellation()
        guard let container else {
            throw RecorderError.modelNotReady
        }
        let parameters = GenerateParameters(
            maxTokens: request.maxTokens,
            maxKVSize: maxKVSize,
            temperature: Float(request.temperature),
            topP: 0.9,
            repetitionPenalty: 1.05
        )
        let session = ChatSession(
            container,
            instructions: request.systemPrompt,
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false]
        )
        let text = try await session.respond(to: request.userPrompt)
        try Task.checkCancellation()
        return TextCompletionResult(text: text)
    }
}

/// MLX Hugging Face repository downloader — wraps `MLXLMCommon.downloadModel`
/// with an app-scoped `HubApi` base so snapshot bytes land inside the model's
/// install root, and resume/layout stay upstream-owned.
public struct MLXRepositoryDownloader: ModelContentDownloader {
    public init() {}

    public func download(
        descriptor: ModelDescriptor,
        into directory: URL,
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws -> URL {
        guard case .mlxRepository(let id, let revision) = descriptor.installMethod else {
            throw PhoneAIError.unsupportedInstallMethod("MLXRepositoryDownloader only handles .mlxRepository")
        }
        let hub = HubApi(downloadBase: directory)
        let expected = descriptor.expectedBytes
        return try await downloadModel(
            hub: hub,
            configuration: .init(id: id, revision: revision)
        ) { p in
            if let expected, expected > 0 {
                progress(Int64(p.fractionCompleted * Double(expected)), expected)
            } else {
                progress(p.completedUnitCount, p.totalUnitCount > 0 ? p.totalUnitCount : nil)
            }
        }
    }

    public func verify(descriptor: ModelDescriptor, installedAt directory: URL) async -> Bool {
        let fm = FileManager.default
        var sawWeights = false
        var sawConfig = false
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "safetensors" { sawWeights = true }
            if url.lastPathComponent == "config.json" { sawConfig = true }
        }
        return sawWeights && sawConfig
    }
}
#endif
