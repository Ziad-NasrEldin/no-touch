import Foundation

/// Candidate on-device models recorded as unmeasured placeholders for A1.
/// None are vendored or depended on in Phase 0; selection requires measured
/// accuracy, processing time, memory, heat, and battery evidence on the
/// iPhone 14 Pro Max. No cloud fallback, no Apple Intelligence requirement.
public enum AIModelCandidateCatalog {
    /// Multilingual Whisper via WhisperKit — transcription, not translation.
    /// Compare compressed large-v3 Turbo vs a smaller multilingual model.
    public static let whisperLargeV3Turbo = "whisperkit-large-v3-turbo"
    public static let whisperSmallMultilingual = "whisperkit-small-multilingual"

    /// Small quantized multilingual text model candidate for grouping,
    /// titles, summaries, and categories (e.g. via MLX or llama.cpp runtime).
    public static let qwen3_1_7B = "qwen3-1.7b-quantized"
}
