import AVFoundation

/// Keeps the iPhone app running in the background while the watch is
/// recording, so clips are transcribed the moment they arrive instead of
/// waiting for iOS to grant a background task.
///
/// How: an `AVAudioEngine` plays silence through a `.playback` session that
/// mixes with other audio (music, calls and other apps are unaffected), which
/// together with the `audio` background mode stops iOS suspending the app.
/// This is fine for personal/TestFlight use; App Review would reject it for
/// an App Store release.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var observers: [NSObjectProtocol] = []
    private(set) var isActive = false

    /// Readable from any isolation (the coordinator's drain policy asks).
    nonisolated(unsafe) private(set) static var isRunning = false

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        let frames = AVAudioFrameCount(format.sampleRate) // 1 s of silence
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            silence.frameLength = frames // zero-filled
            buffer = silence
        }
        let center = NotificationCenter.default
        // Calls, Siri or another app taking audio stop the engine; restart after.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor in self?.restartIfNeeded() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartIfNeeded() }
        })
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        Self.isRunning = true
        restartIfNeeded()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        Self.isRunning = false
        player.stop()
        engine.stop()
    }

    /// Re-engages the silent keep-alive engine if watch capture is still live
    /// (e.g., after local recording playback stops or an audio interruption ends).
    func resumeIfNeeded() {
        restartIfNeeded()
    }

    private func restartIfNeeded() {
        guard isActive, let buffer else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying {
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                player.play()
            }
        } catch {
            // Retried on the next interruption-ended / state change.
        }
    }
}
