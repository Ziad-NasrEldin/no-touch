import AudioCapture

/// Module-internal & public aliases preserving the existing `WatchCapture`
/// surface (`WatchDiagnostics`, `CapturePaths`, `CaptureSessionStore`) after
/// factoring the shared chunked-capture core into `AudioCapture`.
public typealias WatchDiagnostics = AudioCapture.CaptureDiagnostics
typealias CapturePaths = AudioCapture.CapturePaths
typealias CaptureSessionStore = AudioCapture.CaptureSessionStore
