import CryptoKit
import Foundation
import RecorderContracts

/// Device-uptime seconds for chunk ordering. Monotonic while the watch is
/// awake; wall timestamps anchor real time across clock changes.
enum Monotonic {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// Multicast, replaying broadcaster for `RecordingSession` state. The actor
/// publishes through this lock-guarded type so the nonisolated `stateUpdates()`
/// never has to hop isolation and every subscriber first sees the latest truth.
final class SessionStateBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingSession>.Continuation] = [:]
    private var latest: RecordingSession?

    func stream() -> AsyncStream<RecordingSession> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let current = latest
            lock.unlock()
            if let current { continuation.yield(current) }
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    /// Seeds `latest` at init so the first subscriber replays recovered state.
    func prime(_ session: RecordingSession?) {
        lock.lock()
        latest = session
        lock.unlock()
    }

    func yield(_ session: RecordingSession) {
        lock.lock()
        latest = session
        let sinks = Array(continuations.values)
        lock.unlock()
        for sink in sinks { sink.yield(session) }
    }
}

/// Real implementation of `WatchCaptureServiceProtocol`: drives AVAudioSession
/// + AVAudioRecorder through one session per "recording day", rotating mono
/// 16 kHz AAC `.m4a` chunks every `chunkDuration` seconds, persisting session
/// truth and chunk manifests atomically, and reporting honest gaps as
/// `InterruptionInterval`s — never implied silence.
public actor WatchCaptureService: WatchCaptureServiceProtocol {
    /// 60 s chunks bound worst-case loss per crash to one minute while keeping
    /// ~1,440 files/day — small enough for WCSession to drain steadily.
    public static let defaultChunkDuration: TimeInterval = 60
    /// Metering VAD threshold: average power above −40 dBFS counts as speech.
    static let speechThresholdDBFS: Float = -40
    static let vadAlgorithm = "avg-power/1s/-40dBFS"
    /// Refuse to start a chunk under this much free space; fail visibly.
    static let minimumFreeBytes: UInt64 = 32 * 1_024 * 1_024
    private static let chunkFormat = AudioChunkFormat(
        container: "m4a", codec: "aac", sampleRate: 16_000, channelCount: 1
    )

    private let paths: CapturePaths
    private let store: CaptureSessionStore
    private let outbox: (any WatchTransferServiceProtocol)?
    private let diagnostics: WatchDiagnostics
    private let chunkDuration: TimeInterval
    private let broadcaster = SessionStateBroadcaster()
    private let eventSink: AsyncStream<CaptureEngineEvent>.Continuation

    private var session: RecordingSession?
    private var nextSequence = 0
    private var finalized: [AudioChunkMetadata] = []
    private var engine: (any CaptureEngine)?
    private var activeChunkURL: URL?
    private var loopTask: Task<Void, Never>?
    /// Assigned inside the nonisolated initializer; touched only by
    /// init/deinit afterwards, so bypassing isolation is race-free.
    private nonisolated(unsafe) var eventTask: Task<Void, Never>?
    private nonisolated(unsafe) var interruptionTask: Task<Void, Never>?

    private var chunkEndsAt: ContinuousClock.Instant = .now
    private var chunkWallStart = Date()
    private var chunkMonoStart = 0.0
    private var ticksSinceHeartbeat = 0
    private var speechSeconds = 0.0
    private var silenceSeconds = 0.0
    private var wasRecordingBeforeInterruption = false

    public init(
        outbox: (any WatchTransferServiceProtocol)? = nil,
        diagnostics: WatchDiagnostics? = nil,
        directory: URL? = nil,
        chunkDuration: TimeInterval = WatchCaptureService.defaultChunkDuration
    ) {
        let paths = WatchCaptureService.resolvePaths(directory: directory)
        self.paths = paths
        self.store = CaptureSessionStore(paths: paths)
        self.outbox = outbox
        self.diagnostics = diagnostics ?? WatchDiagnostics(directory: paths.root)
        self.chunkDuration = chunkDuration
        let (stream, sink) = AsyncStream<CaptureEngineEvent>.makeStream()
        self.eventSink = sink
        if let recovered = Self.recoverAfterRelaunch(
            store: store, diagnostics: self.diagnostics, now: Date()
        ) {
            session = recovered.session
            nextSequence = recovered.nextSequence
            finalized = recovered.finalized
        }
        var initPayload: [String: String] = [
            "platformSupported": "\(PlatformCaptureEngine.isSupported)"
        ]
        if let s = session {
            initPayload["state"] = s.state.rawValue
            initPayload["sessionID"] = s.id.uuidString
        }
        self.diagnostics.emit(.lifecycle, name: "capture-service-init", payload: initPayload)
        broadcaster.prime(session)
        self.eventTask = makeEventPump(consuming: stream)
        // Session interruptions are process-wide; forwarded into the same
        // stream so the actor serializes every capture event.
        self.interruptionTask = Self.makeInterruptionPump(sink: sink)
    }

    /// Nonisolated so it may be invoked from the nonisolated initializer —
    /// the `self` capture happens here, not in init.
    private nonisolated func makeEventPump(
        consuming stream: AsyncStream<CaptureEngineEvent>
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handleEngineEvent(event)
            }
        }
    }

    private static nonisolated func makeInterruptionPump(
        sink: AsyncStream<CaptureEngineEvent>.Continuation
    ) -> Task<Void, Never> {
        Task {
            for await event in PlatformCaptureEngine.interruptionEvents() {
                sink.yield(event)
            }
        }
    }

    deinit {
        loopTask?.cancel()
        eventTask?.cancel()
        interruptionTask?.cancel()
    }

    private static func resolvePaths(directory: URL?) -> CapturePaths {
        if let directory, let paths = try? CapturePaths.makeCustom(root: directory) {
            return paths
        }
        if let paths = try? CapturePaths.makeDefault() {
            return paths
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WatchCapture-\(UUID().uuidString)", isDirectory: true)
        return (try? CapturePaths.makeCustom(root: tmp)) ?? CapturePaths(root: tmp)
    }

    // MARK: - WatchCaptureServiceProtocol

    public func startSession() async throws -> RecordingSession {
        guard PlatformCaptureEngine.isSupported else { throw RecorderError.notImplemented }
        if let session, session.state == .recording { return session }
        if let session, session.state == .paused || session.state == .interrupted {
            return try await resumeOnSameSession(now: Date(), via: "start-resume")
        }
        let now = Date()
        session = RecordingSession(state: .idle, startedAt: now)
        finalized = []
        nextSequence = 0
        try await activateAndRecord(now: now, via: "start")
        return session ?? RecordingSession()
    }

    public func pauseSession() async throws -> RecordingSession {
        guard var current = session, current.state == .recording else {
            throw RecorderError.invalidState(session?.state ?? .idle)
        }
        sealActiveChunk(endedAt: Date(), via: "pause")
        haltLoop()
        PlatformCaptureEngine.deactivateAudioSession()
        current.state = .paused
        session = current
        diagnostics.emit(.capture, name: "capture-paused", payload: sessionPayload())
        commit()
        return current
    }

    public func resumeSession() async throws -> RecordingSession {
        guard let current = session, current.state == .paused || current.state == .interrupted else {
            throw RecorderError.invalidState(session?.state ?? .idle)
        }
        return try await resumeOnSameSession(now: Date(), via: "resume")
    }

    public func stopSession() async throws -> RecordingSession {
        guard var current = session, current.state != .idle, current.state != .stopped else {
            throw RecorderError.invalidState(session?.state ?? .idle)
        }
        let now = Date()
        sealActiveChunk(endedAt: now, via: "stop")
        haltLoop()
        PlatformCaptureEngine.deactivateAudioSession()
        current.state = .stopped
        current.stoppedAt = now
        current.failureReason = nil
        closeOpenInterval(at: now)
        session = current
        wasRecordingBeforeInterruption = false
        diagnostics.emit(.capture, name: "capture-stopped", payload: sessionPayload())
        commit()
        return current
    }

    public func currentSession() -> RecordingSession? {
        session
    }

    public func finalizedChunks(sessionID: UUID) -> [AudioChunkMetadata] {
        session?.id == sessionID ? finalized : store.loadManifest(sessionID: sessionID)
    }

    public nonisolated func stateUpdates() -> AsyncStream<RecordingSession> {
        broadcaster.stream()
    }

    // MARK: - App lifecycle honesty

    /// Backgrounding with an active audio session keeps capturing under the
    /// supported audio background mode — recorded as lifecycle evidence, not
    /// as a gap. If capture actually dies, the relaunch gap covers it.
    public func appDidBecomeActive() {
        diagnostics.emit(.lifecycle, name: "app-active", payload: sessionPayload())
    }

    public func appWillResignActive() {
        diagnostics.emit(.lifecycle, name: "app-resign-active", payload: sessionPayload())
    }

    public func appDidEnterBackground() {
        diagnostics.emit(.lifecycle, name: "app-background", payload: sessionPayload())
    }

    // MARK: - Recording pipeline

    private func resumeOnSameSession(now: Date, via: String) async throws -> RecordingSession {
        try await activateAndRecord(now: now, via: via)
        return session ?? RecordingSession()
    }

    /// Permission → audio session → chunk engine. Any failure marks the
    /// session interrupted with an honest reason instead of pretending.
    private func activateAndRecord(now: Date, via: String) async throws {
        do {
            try await ensureMicrophonePermission()
            try PlatformCaptureEngine.activateAudioSession()
            try beginChunk(at: now)
        } catch {
            let reason = failureReason(for: error)
            if var s = session {
                s.state = .interrupted
                s.failureReason = reason
                if s.interruptionIntervals.last?.endedAt != nil || s.interruptionIntervals.isEmpty {
                    s.interruptionIntervals.append(InterruptionInterval(beganAt: now, reason: reason))
                }
                session = s
            }
            diagnostics.emit(.capture, name: "capture-start-failed", severity: .error,
                             payload: ["via": via, "error": "\(error)"])
            commit()
            throw error
        }
        if var s = session {
            // Capture is confirmed running again — the gap ends now.
            if let open = s.interruptionIntervals.lastIndex(where: { $0.endedAt == nil }) {
                s.interruptionIntervals[open].endedAt = now
            }
            s.state = .recording
            s.failureReason = nil
            s.startedAt = s.startedAt ?? now
            s.stoppedAt = nil
            s.lastConfirmedCaptureAt = now
            session = s
        }
        wasRecordingBeforeInterruption = false
        startLoop()
        diagnostics.emit(.capture, name: "capture-\(via)", payload: sessionPayload())
        commit()
    }

    private func ensureMicrophonePermission() async throws {
        switch PlatformCaptureEngine.microphonePermission() {
        case .granted:
            return
        case .denied:
            throw RecorderError.microphoneDenied
        case .undetermined:
            if await PlatformCaptureEngine.requestMicrophoneAccess() {
                return
            }
            throw RecorderError.microphoneDenied
        }
    }

    /// Creates the next chunk engine and starts it. Caller must have an
    /// active audio session already.
    private func beginChunk(at now: Date) throws {
        guard let sessionID = session?.id else { throw RecorderError.invalidState(.idle) }
        try ensureFreeSpace()
        let directory = paths.chunksDirectory(sessionID: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(sequence: nextSequence))
        let newEngine = PlatformCaptureEngine(fileURL: url) { [eventSink] event in
            eventSink.yield(event)
        }
        try newEngine.prepare()
        chunkWallStart = now
        chunkMonoStart = Monotonic.now()
        try newEngine.start()
        engine = newEngine
        activeChunkURL = url
        chunkEndsAt = .now + .seconds(chunkDuration)
        resetMeters()
    }

    private static func fileName(sequence: Int) -> String {
        "chunk-\(String(format: "%06d", sequence))-\(UUID().uuidString.prefix(8)).m4a"
    }

    private func startLoop() {
        haltLoop()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.tick()
            }
        }
    }

    private func haltLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func tick() {
        guard session?.state == .recording, let engine else { return }
        guard engine.isCapturing else {
            handleUnexpectedCaptureLoss()
            return
        }
        if let power = engine.sampleAveragePower() {
            if power > Self.speechThresholdDBFS {
                speechSeconds += 1
            } else {
                silenceSeconds += 1
            }
        }
        ticksSinceHeartbeat += 1
        if ticksSinceHeartbeat >= 10 {
            ticksSinceHeartbeat = 0
            if var s = session {
                s.lastConfirmedCaptureAt = Date()
                session = s
            }
            persist()
        }
        if ContinuousClock.now >= chunkEndsAt {
            rotateChunk()
        }
    }

    /// Prepares the next recorder while the current one still runs so the gap
    /// between chunks is only the stop→start latency, then swaps and seals the
    /// old file. Real measured stamps — rotation gaps show up truthfully in
    /// monotonic time rather than being hidden.
    private func rotateChunk() {
        guard let old = engine, let sessionID = session?.id else { return }
        let directory = paths.chunksDirectory(sessionID: sessionID)
        let nextURL = directory.appendingPathComponent(Self.fileName(sequence: nextSequence))
        let next = PlatformCaptureEngine(fileURL: nextURL) { [eventSink] event in
            eventSink.yield(event)
        }
        do {
            try next.prepare()
        } catch {
            // Keep the running chunk going; retry rotation shortly.
            chunkEndsAt = .now + .seconds(15)
            diagnostics.emit(.capture, name: "rotate-prepare-failed", severity: .error,
                             payload: ["error": "\(error)", "seq": "\(nextSequence)"])
            return
        }
        // Capture the retiring chunk's identity and stamps before swapping —
        // the swap writes the *new* chunk's start values into the same slots.
        let oldURL = activeChunkURL
        let oldWallStart = chunkWallStart
        let oldMonoStart = chunkMonoStart
        let wallEnd = Date()
        let monoEnd = Monotonic.now()
        old.stop()
        let duration = old.capturedDuration
        let wallStart = Date()
        let monoStart = Monotonic.now()
        do {
            try next.start()
        } catch {
            sealChunk(url: oldURL,
                      wallStart: oldWallStart, wallEnd: wallEnd,
                      monoStart: oldMonoStart, monoEnd: monoEnd,
                      duration: duration, via: "rotate")
            self.engine = nil
            activeChunkURL = nil
            wasRecordingBeforeInterruption = true
            beginInterruption(at: wallStart, reason: .unknown,
                              detail: "rotate-start-failed: \(error)")
            return
        }
        self.engine = next
        activeChunkURL = nextURL
        chunkWallStart = wallStart
        chunkMonoStart = monoStart
        chunkEndsAt = .now + .seconds(chunkDuration)
        sealChunk(url: oldURL,
                  wallStart: oldWallStart, wallEnd: wallEnd,
                  monoStart: oldMonoStart, monoEnd: monoEnd,
                  duration: duration, via: "rotate")
        resetMeters()
    }

    /// Stops the active engine and seals whatever audio the file holds —
    /// the shared "preserve completed audio" path for pause, stop,
    /// interruption, and failure handling.
    private func sealActiveChunk(endedAt wallEnd: Date, via: String) {
        guard let engine else { return }
        let monoEnd = Monotonic.now()
        engine.stop()
        let duration = engine.capturedDuration
        sealChunk(url: activeChunkURL,
                  wallStart: chunkWallStart, wallEnd: wallEnd,
                  monoStart: chunkMonoStart, monoEnd: monoEnd,
                  duration: duration, via: via)
        self.engine = nil
        activeChunkURL = nil
    }

    /// Hashes and registers one sealed chunk file. Empty/missing files are
    /// dropped with a warning — a zero-byte file is not evidence of audio.
    private func sealChunk(
        url: URL?,
        wallStart: Date, wallEnd: Date,
        monoStart: Double, monoEnd: Double,
        duration: TimeInterval, via: String
    ) {
        guard let sessionID = session?.id, let url else { return }
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.intValue,
            size > 0
        else {
            diagnostics.emit(.capture, name: "chunk-empty-dropped", severity: .warning,
                             payload: ["via": via, "file": url.lastPathComponent])
            return
        }
        do {
            let integrity = ChunkIntegrity(
                sha256Hex: try Self.sha256Hex(of: url),
                byteCount: size,
                duration: duration,
                sequenceNumber: nextSequence,
                monotonicStartSeconds: monoStart,
                monotonicEndSeconds: monoEnd,
                wallStartedAt: wallStart,
                wallEndedAt: wallEnd,
                voiceActivity: VoiceActivitySummary(
                    speechSeconds: speechSeconds,
                    silenceSeconds: silenceSeconds,
                    algorithmIdentifier: Self.vadAlgorithm
                )
            )
            let metadata = AudioChunkMetadata(
                sessionID: sessionID,
                fileName: url.lastPathComponent,
                format: Self.chunkFormat,
                integrity: integrity
            )
            nextSequence += 1
            finalized.append(metadata)
            if var s = session {
                s.lastConfirmedCaptureAt = wallEnd
                session = s
            }
            persist()
            diagnostics.emit(.capture, name: "chunk-finalized", payload: [
                "via": via,
                "seq": "\(integrity.sequenceNumber)",
                "bytes": "\(size)",
                "seconds": String(format: "%.1f", duration),
                "sha256": String(integrity.sha256Hex.prefix(16))
            ])
            if let outbox {
                Task { [diagnostics] in
                    do {
                        try await outbox.enqueueForTransfer(metadata)
                    } catch {
                        diagnostics.emit(.transfer, name: "enqueue-failed",
                                         severity: .error,
                                         payload: ["chunkID": metadata.id.uuidString,
                                                   "error": "\(error)"])
                    }
                }
            }
        } catch {
            diagnostics.emit(.capture, name: "chunk-seal-failed", severity: .error,
                             payload: ["file": url.lastPathComponent, "error": "\(error)"])
        }
    }

    // MARK: - Interruption bookkeeping

    private func handleEngineEvent(_ event: CaptureEngineEvent) {
        switch event {
        case .interruptionBegan:
            interruptionBegan()
        case .interruptionEnded(let shouldResume):
            interruptionEnded(shouldResume: shouldResume)
        case .encodeError(let message):
            encodeError(message)
        }
    }

    private func interruptionBegan() {
        guard session?.state == .recording else {
            diagnostics.emit(.capture, name: "interruption-ignored",
                             payload: ["state": session?.state.rawValue ?? "none"])
            return
        }
        wasRecordingBeforeInterruption = true
        sealActiveChunk(endedAt: Date(), via: "interruption")
        beginInterruption(at: Date(), reason: .audioSessionInterrupted,
                          detail: "audio-session")
    }

    /// The gap stays open until capture is confirmed again — an interval
    /// measures missing audio, not the system event. If no resume happens,
    /// `stopSession` closes it at stop time; either way every second inside
    /// it is genuinely uncaptured.
    private func interruptionEnded(shouldResume: Bool) {
        diagnostics.emit(.capture, name: "interruption-ended",
                         payload: ["shouldResume": "\(shouldResume)"])
        guard session?.state == .interrupted, wasRecordingBeforeInterruption, shouldResume else {
            wasRecordingBeforeInterruption = false
            return
        }
        wasRecordingBeforeInterruption = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.activateAndRecord(now: Date(), via: "auto-resume")
            } catch {
                // Remains .interrupted; activateAndRecord already recorded the why.
            }
        }
    }

    private func encodeError(_ message: String) {
        guard session?.state == .recording else { return }
        wasRecordingBeforeInterruption = true
        sealActiveChunk(endedAt: Date(), via: "encode-error")
        let reason: FailureReason = freeSpaceIsLow() ? .lowStorage : .unknown
        beginInterruption(at: Date(), reason: reason, detail: "encode: \(message)")
        guard reason != .lowStorage else { return }
        scheduleAutoRecovery(via: "encode-retry")
    }

    /// The recorder stopped without telling us (watched by the 1 s tick).
    private func handleUnexpectedCaptureLoss() {
        wasRecordingBeforeInterruption = true
        sealActiveChunk(endedAt: Date(), via: "capture-loss")
        beginInterruption(at: Date(), reason: .unknown, detail: "engine-not-capturing")
        scheduleAutoRecovery(via: "auto-recover")
    }

    /// One bounded automatic recovery attempt: waits briefly, then resumes
    /// only if still interrupted — spec allows recovery "when the system
    /// allows it"; a user who pauses/stops in the meantime cancels it.
    private func scheduleAutoRecovery(via: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.autoRecoverIfInterrupted(via: via)
        }
    }

    private func autoRecoverIfInterrupted(via: String) async {
        guard session?.state == .interrupted else { return }
        try? await activateAndRecord(now: Date(), via: via)
    }

    private func beginInterruption(at now: Date, reason: FailureReason, detail: String) {
        haltLoop()
        if var s = session {
            s.state = .interrupted
            s.failureReason = reason
            if s.interruptionIntervals.last?.endedAt != nil || s.interruptionIntervals.isEmpty {
                s.interruptionIntervals.append(InterruptionInterval(beganAt: now, reason: reason))
            }
            session = s
        }
        diagnostics.emit(.capture, name: "interruption-began", severity: .warning,
                         payload: ["reason": reason.rawValue, "detail": detail])
        commit()
    }

    private func closeOpenInterval(at now: Date) {
        guard var s = session,
              let index = s.interruptionIntervals.lastIndex(where: { $0.endedAt == nil })
        else { return }
        s.interruptionIntervals[index].endedAt = now
        session = s
    }

    // MARK: - Relaunch gap recovery

    /// A session persisted mid-recording means the process died. Everything
    /// between the last confirmed capture and now is unknown/missing audio —
    /// recorded as such, and chunk files no manifest claims are removed.
    /// Static so it can run inside the nonisolated actor initializer.
    private static func recoverAfterRelaunch(
        store: CaptureSessionStore,
        diagnostics: WatchDiagnostics,
        now: Date
    ) -> (session: RecordingSession, nextSequence: Int, finalized: [AudioChunkMetadata])? {
        guard let persisted = store.load() else { return nil }
        var s = persisted.session
        var relaunchGap = false
        if s.state == .recording || s.state == .interrupted {
            if let open = s.interruptionIntervals.lastIndex(where: { $0.endedAt == nil }) {
                s.interruptionIntervals[open].endedAt = now
            } else {
                let gapStart = s.lastConfirmedCaptureAt ?? s.startedAt ?? now
                s.interruptionIntervals.append(
                    InterruptionInterval(beganAt: gapStart, endedAt: now,
                                       reason: .unrecoverableTermination)
                )
            }
            s.state = .interrupted
            s.failureReason = .unrecoverableTermination
            relaunchGap = true
        }
        let finalized = store.loadManifest(sessionID: s.id)
        let nextSequence = persisted.nextSequence
        try? store.save(PersistedCapture(session: s, nextSequence: nextSequence))
        if relaunchGap {
            diagnostics.emit(.lifecycle, name: "relaunch-gap", severity: .warning, payload: [
                "sessionID": s.id.uuidString,
                "lastConfirmed": s.lastConfirmedCaptureAt.map { "\($0.timeIntervalSince1970)" } ?? "none"
            ])
        }
        discardOrphanedChunks(
            store: store,
            diagnostics: diagnostics,
            activeSessionID: s.id,
            activeManifest: finalized
        )
        return (s, nextSequence, finalized)
    }

    private static func discardOrphanedChunks(
        store: CaptureSessionStore,
        diagnostics: WatchDiagnostics,
        activeSessionID: UUID,
        activeManifest: [AudioChunkMetadata]
    ) {
        for directory in store.allChunkSessionDirectories() {
            guard let sessionID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let manifest = sessionID == activeSessionID
                ? activeManifest
                : store.loadManifest(sessionID: sessionID)
            for url in store.orphanedChunkFiles(sessionID: sessionID, manifest: manifest) {
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                    as? NSNumber)?.intValue ?? 0
                try? FileManager.default.removeItem(at: url)
                diagnostics.emit(.capture, name: "orphan-chunk-discarded", severity: .warning,
                                 payload: ["sessionID": sessionID.uuidString,
                                           "file": url.lastPathComponent,
                                           "bytes": "\(size)"])
            }
        }
    }

    // MARK: - Persistence / helpers

    private func commit() {
        persist()
        if let s = session { broadcaster.yield(s) }
    }

    private func persist() {
        guard let s = session else { return }
        do {
            try store.save(PersistedCapture(session: s, nextSequence: nextSequence))
            try store.saveManifest(sessionID: s.id, chunks: finalized)
        } catch {
            diagnostics.emit(.capture, name: "persist-failed", severity: .error,
                             payload: ["error": "\(error)"])
        }
    }

    /// `volumeAvailableCapacityForImportantUsage` is unavailable on watchOS;
    /// the plain capacity key is the honest floor check that exists there.
    private func freeBytesAvailable() -> UInt64? {
        guard
            let values = try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
            let free = values.volumeAvailableCapacity,
            free >= 0
        else { return nil }
        return UInt64(free)
    }

    private func ensureFreeSpace() throws {
        if let free = freeBytesAvailable(), free < Self.minimumFreeBytes {
            throw RecorderError.lowStorage
        }
    }

    private func freeSpaceIsLow() -> Bool {
        if let free = freeBytesAvailable() {
            return free < Self.minimumFreeBytes
        }
        return false
    }

    private func failureReason(for error: Error) -> FailureReason {
        switch error as? RecorderError {
        case .microphoneDenied: return .microphoneDenied
        case .lowStorage: return .lowStorage
        default: return .unknown
        }
    }

    private func resetMeters() {
        speechSeconds = 0
        silenceSeconds = 0
    }

    private func sessionPayload() -> [String: String] {
        var payload: [String: String] = ["state": session?.state.rawValue ?? "none"]
        if let s = session {
            payload["sessionID"] = s.id.uuidString
            payload["seq"] = "\(nextSequence)"
            payload["chunks"] = "\(finalized.count)"
            payload["gaps"] = "\(s.interruptionIntervals.count)"
        }
        return payload
    }

    private static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
