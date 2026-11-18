import Foundation

/// One remote file for direct-URL installs (`files` method). `sha256Hex` and
/// `expectedBytes` are optional but at least one should be present for
/// meaningful verification.
public struct ModelFile: Codable, Sendable, Equatable {
    public var url: URL
    public var relativePath: String
    public var sha256Hex: String?
    public var expectedBytes: Int64?

    public init(url: URL, relativePath: String, sha256Hex: String? = nil, expectedBytes: Int64? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.sha256Hex = sha256Hex
        self.expectedBytes = expectedBytes
    }
}

/// How a descriptor's bytes reach the device. Repository methods delegate to
/// the vendored downloader of the matching package so layout, resume, and
/// token handling stay upstream-owned.
public enum ModelInstallMethod: Codable, Sendable, Equatable {
    /// Argmax WhisperKit CoreML model folder inside `argmaxinc/whisperkit-coreml`
    /// (or a fork) — e.g. variant `large-v3-v20240930_626MB`.
    case whisperKitRepository(variant: String, repo: String)
    /// MLX-format weights on Hugging Face, e.g. `mlx-community/Qwen3-1.7B-4bit`.
    case mlxRepository(id: String, revision: String)
    /// Plain HTTPS file(s) downloaded into the model directory.
    case files([ModelFile])
}

public enum ModelKind: String, Codable, Sendable {
    case speech
    case textIntelligence
}

/// A selectable local model. `expectedBytes`/`minimumFreeBytes` guard the
/// install flow; `modelVersion` is stamped on every produced artifact so
/// reprocessing after a model change stays explainable.
public struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ModelKind
    public var displayName: String
    public var modelVersion: String
    public var installMethod: ModelInstallMethod
    /// Best-known on-disk size; used for progress and free-space checks.
    public var expectedBytes: Int64?
    /// Free space required at install start (payload + working room).
    public var minimumFreeBytes: Int64
    /// Languages the variant covers. Must never be English-only for this app.
    public var languages: [String]

    public init(
        id: String,
        kind: ModelKind,
        displayName: String,
        modelVersion: String,
        installMethod: ModelInstallMethod,
        expectedBytes: Int64? = nil,
        minimumFreeBytes: Int64 = 0,
        languages: [String]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.modelVersion = modelVersion
        self.installMethod = installMethod
        self.expectedBytes = expectedBytes
        self.minimumFreeBytes = minimumFreeBytes
        self.languages = languages
    }
}

/// Measured-candidate catalog. Sizes are repo-reported approximations used
/// only for progress/free-space UX — the verified byte count recorded after
/// install is authoritative.
public enum PhoneAIModelCatalog {
    /// Compressed large-v3 Turbo — Argmax's recommended iOS/macOS variant.
    /// Multilingual (ar + en + ~99 others). ~626 MB download.
    public static let whisperLargeV3Turbo = ModelDescriptor(
        id: AIModelCandidateCatalog.whisperLargeV3Turbo,
        kind: .speech,
        displayName: "Whisper large-v3 Turbo (compressed)",
        modelVersion: "whisperkit/openai_whisper-large-v3-v20240930_626MB",
        installMethod: .whisperKitRepository(
            variant: "large-v3-v20240930_626MB",
            repo: "argmaxinc/whisperkit-coreml"
        ),
        expectedBytes: 626_000_000,
        minimumFreeBytes: 1_400_000_000,
        languages: ["ar", "en"]
    )

    /// Smaller multilingual fallback for tighter memory/thermal budgets.
    /// ~500 MB download. Kept as a Gate A comparison candidate.
    public static let whisperSmall = ModelDescriptor(
        id: AIModelCandidateCatalog.whisperSmallMultilingual,
        kind: .speech,
        displayName: "Whisper small (multilingual)",
        modelVersion: "whisperkit/openai_whisper-small",
        installMethod: .whisperKitRepository(
            variant: "small",
            repo: "argmaxinc/whisperkit-coreml"
        ),
        expectedBytes: 500_000_000,
        minimumFreeBytes: 1_100_000_000,
        languages: ["ar", "en"]
    )

    /// Primary text-intelligence candidate: Qwen3 1.7B, 4-bit MLX.
    /// ~1.1 GB download. Arabic-capable multilingual instruct model.
    public static let qwen3_1_7b_4bit = ModelDescriptor(
        id: AIModelCandidateCatalog.qwen3_1_7B,
        kind: .textIntelligence,
        displayName: "Qwen3 1.7B Instruct (4-bit MLX)",
        modelVersion: "mlx-community/Qwen3-1.7B-4bit",
        installMethod: .mlxRepository(id: "mlx-community/Qwen3-1.7B-4bit", revision: "main"),
        expectedBytes: 1_100_000_000,
        minimumFreeBytes: 2_400_000_000,
        languages: ["ar", "en"]
    )

    /// Even smaller fallback (~400 MB) for the same engine seam, evaluated as
    /// a Gate A fallback if 1.7B doesn't fit memory/thermal budgets.
    public static let qwen3_0_6b_4bit = ModelDescriptor(
        id: "qwen3-0.6b-4bit-mlx",
        kind: .textIntelligence,
        displayName: "Qwen3 0.6B Instruct (4-bit MLX)",
        modelVersion: "mlx-community/Qwen3-0.6B-4bit",
        installMethod: .mlxRepository(id: "mlx-community/Qwen3-0.6B-4bit", revision: "main"),
        expectedBytes: 400_000_000,
        minimumFreeBytes: 900_000_000,
        languages: ["ar", "en"]
    )

    public static let speechCandidates: [ModelDescriptor] = [
        whisperLargeV3Turbo, whisperSmall,
    ]

    public static let textIntelligenceCandidates: [ModelDescriptor] = [
        qwen3_1_7b_4bit, qwen3_0_6b_4bit,
    ]
}
