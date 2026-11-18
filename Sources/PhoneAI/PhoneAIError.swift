import Foundation

/// PhoneAI-internal failures that don't map onto the frozen `RecorderError`
/// vocabulary. Contract-semantic failures (`modelNotReady`,
/// `integrityMismatch`, `lowStorage`, `storageFailure`, `notFound`,
/// `notImplemented`) still surface as `RecorderError`.
public enum PhoneAIError: Error, Sendable, Equatable {
    /// The model descriptor has no usable install method or is malformed.
    case invalidModelDescriptor(String)
    /// No downloader is compiled in for the descriptor's install method
    /// (e.g. WhisperKit/MLX package not yet registered on the target).
    case unsupportedInstallMethod(String)
    /// The audio file could not be decoded to PCM for the engine.
    case audioDecodingFailed(String)
    /// The input file exceeds the configured processing bound.
    case inputExceedsBound(String)
    /// The engine produced output that could not be grounded in the input.
    case ungroundedOutput(String)
    /// Downloaded bytes did not match the declared expectations.
    case verificationFailed(String)
}
