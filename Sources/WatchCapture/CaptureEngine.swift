import Foundation
import RecorderContracts

/// Events the platform capture engine reports to `WatchCaptureService`.
/// Interruptions are session-level; encode errors arrive per recorder.
enum CaptureEngineEvent: Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case encodeError(String)
}

enum MicrophonePermission: Sendable {
    case granted
    case denied
    case undetermined
}

/// One chunk recorder plus the audio-session surface it needs. The service
/// only talks to `PlatformCaptureEngine`, so the macOS host build compiles an
/// honest stub while the watchOS build binds AVFoundation.
protocol CaptureEngine: Sendable {
    static var isSupported: Bool { get }
    static func microphonePermission() -> MicrophonePermission
    static func requestMicrophoneAccess() async -> Bool
    static func activateAudioSession() throws
    static func deactivateAudioSession()
    static func interruptionEvents() -> AsyncStream<CaptureEngineEvent>

    init(fileURL: URL, onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void)
    var fileURL: URL { get }
    /// Opens the chunk file and readies the recorder. May be called while a
    /// previous engine still records so rotation stays tight.
    func prepare() throws
    func start() throws
    /// Finalizes the file. Safe to call on a recorder the system already
    /// stopped, which lets interruption handling salvage a partial chunk.
    func stop()
    var isCapturing: Bool { get }
    var capturedDuration: TimeInterval { get }
    /// Updates meters and returns the channel-0 average power in dBFS,
    /// or nil when metering is unavailable.
    func sampleAveragePower() -> Float?
}

#if os(watchOS)

import AVFoundation

typealias PlatformCaptureEngine = AVChunkRecorder

/// watchOS engine: `AVAudioRecorder` writing one AAC `.m4a` chunk at a time.
/// Chosen over AVAudioEngine because it uses the built-in encoder path, keeps
/// the realtime code trivial, and runs under the supported audio background
/// mode. Session configuration, permission, and interruption observation are
/// statics because they are process-wide.
final class AVChunkRecorder: NSObject, CaptureEngine, AVAudioRecorderDelegate, @unchecked Sendable {
    static var isSupported: Bool { true }

    /// Fresh dictionary per call — `[String: Any]` is not Sendable, so a
    /// shared `static let` would trip strict-concurrency global-state checks.
    private static var settings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    static func microphonePermission() -> MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        // No setPreferredSampleRate on watchOS — the encoder resamples into
        // the requested 16 kHz container rate regardless.
        try session.setActive(true)
    }

    static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Process-wide interruption stream. The observer intentionally lives for
    /// the process lifetime; the closure only extracts Sendable primitives so
    /// nothing non-Sendable crosses into the service.
    static func interruptionEvents() -> AsyncStream<CaptureEngineEvent> {
        interruptionStream
    }

    private static let interruptionStream: AsyncStream<CaptureEngineEvent> = {
        AsyncStream { continuation in
            // Token intentionally retained by NotificationCenter for the
            // process lifetime; nothing non-Sendable leaves the closure.
            _ = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard
                    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                switch type {
                case .began:
                    continuation.yield(.interruptionBegan)
                case .ended:
                    let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
                    continuation.yield(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
                @unknown default:
                    break
                }
            }
        }
    }()

    let fileURL: URL
    private let onEvent: @Sendable (CaptureEngineEvent) -> Void
    private let lock = NSLock()
    private var recorder: AVAudioRecorder?

    required init(fileURL: URL, onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void) {
        self.fileURL = fileURL
        self.onEvent = onEvent
    }

    func prepare() throws {
        let recorder = try AVAudioRecorder(url: fileURL, settings: AVChunkRecorder.settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.prepareToRecord() else { throw RecorderError.storageFailure }
        lock.lock()
        self.recorder = recorder
        lock.unlock()
    }

    func start() throws {
        lock.lock()
        let recorder = self.recorder
        lock.unlock()
        guard let recorder, recorder.record() else {
            throw RecorderError.storageFailure
        }
    }

    func stop() {
        lock.lock()
        let recorder = self.recorder
        lock.unlock()
        recorder?.stop()
    }

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recorder?.isRecording ?? false
    }

    var capturedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return recorder?.currentTime ?? 0
    }

    func sampleAveragePower() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard let recorder, recorder.isRecording else { return nil }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        onEvent(.encodeError(error?.localizedDescription ?? "encode error"))
    }
}

#else

typealias PlatformCaptureEngine = UnsupportedChunkRecorder

/// Non-watchOS stub so `swift build` compiles on the host. Every surface
/// reports the platform honestly instead of pretending to capture.
final class UnsupportedChunkRecorder: CaptureEngine, @unchecked Sendable {
    let fileURL: URL
    static var isSupported: Bool { false }
    static func microphonePermission() -> MicrophonePermission { .denied }
    static func requestMicrophoneAccess() async -> Bool { false }
    static func activateAudioSession() throws { throw RecorderError.notImplemented }
    static func deactivateAudioSession() {}
    static func interruptionEvents() -> AsyncStream<CaptureEngineEvent> {
        AsyncStream { $0.finish() }
    }

    required init(fileURL: URL, onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void) {
        self.fileURL = fileURL
    }
    func prepare() throws { throw RecorderError.notImplemented }
    func start() throws { throw RecorderError.notImplemented }
    func stop() {}
    var isCapturing: Bool { false }
    var capturedDuration: TimeInterval { 0 }
    func sampleAveragePower() -> Float? { nil }
}

#endif
