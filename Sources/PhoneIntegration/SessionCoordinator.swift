import Foundation
import RecorderContracts
import PhoneAI
import PhoneStorage
#if canImport(Darwin)
import Darwin
#endif
#if os(iOS) && canImport(UIKit)
import UIKit
#endif

/// Phase 2 integration seam (I1): owns the phone-side pipeline end-to-end —
/// receive → durable archive → transcription jobs → cross-chunk regrouping →
/// intelligence jobs → generated metadata — plus deletion propagation and
/// the session-truth mirror. The app binds this type and
/// `ExtendedArchiveStoreProtocol`; everything behind it is lane logic.
///
/// Pipeline order inside `processAnalysisQueue` is deliberate and
/// deterministic: transcription drains first (speech engine), then affected
/// sessions regroup (heuristic + bounded model boundary review), then
/// intelligence drains (text engine). Speech and text inference never run
/// concurrently — `ModelExecutionGate` additionally serializes them to cap
/// peak memory on the 6 GB target device.
public actor SessionCoordinator {
    /// Per-pass counts — surfaced to the app shell and diagnostics so the
    /// pipeline's real progress is observable without test scaffolding.
    public struct DrainSummary: Sendable, Equatable {
        public var transcriptionJobs = 0
        public var intelligenceJobs = 0
        public var regroupedSessions = 0
        public var enqueuedIntelligence = 0
        public init() {}
    }

    private let receiveService: PhoneReceiveService
    private let store: SQLiteArchiveStore
    private let transcriber: SpeechTranscriptionAdapter
    private let intelligence: TextIntelligenceAdapter
    private let runner: AnalysisJobRunner
    private var drainScheduled = false
    private var drainAgain = false
    private var drainInFlight = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Gate for opportunistic drains (chunk-arrival kicks, foreground
    /// activation). The app returns false while it is in the background so
    /// GPU/ANE-heavy inference never starts during a short WatchConnectivity
    /// wake — that work belongs to the BGProcessingTask, which calls
    /// `processAnalysisQueue` directly.
    private var canDrainNow: @Sendable () async -> Bool = { true }
    /// Called when work is queued but this process can't run it now.
    private var onDeferredWork: @Sendable () -> Void = {}
    /// The text model (MLX) runs on the GPU, which iOS only allows in the
    /// foreground. While this returns false, grouping + summaries wait and
    /// only transcription (Neural Engine) runs.
    private var allowsTextModel: @Sendable () async -> Bool = { true }

    /// Jobs that failed fewer times than this are retried automatically.
    public static let maxAutomaticAttempts = 3

    public func setDrainPolicy(
        canDrainNow: @escaping @Sendable () async -> Bool,
        onDeferredWork: @escaping @Sendable () -> Void,
        allowsTextModel: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.canDrainNow = canDrainNow
        self.onDeferredWork = onDeferredWork
        self.allowsTextModel = allowsTextModel
    }

    #if os(iOS) && canImport(WatchConnectivity)
    private let transport: WatchConnectivityReceiveTransport
    #endif
    #if os(iOS) && canImport(UIKit)
    /// Owns the memory-warning observer registration (the token unregisters
    /// on its own deinit, so the actor needs no deinit isolation juggling).
    /// Lazy so the observer closure's `self` capture always happens after
    /// init completes; forced on first `activate()`.
    private lazy var memoryWarningToken: ObserverToken? = ObserverToken(
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in await self?.releaseModelMemory() }
        }
    )
    #endif

    // MARK: - Construction

    /// Production wiring: app-owned model root, one shared execution gate,
    /// real adapters bound by availability (WhisperKit/MLXLLM when compiled
    /// in — verify `engineIdentifier` reads "whisperkit"/"mlx-lm", not the
    /// deterministic fallbacks), durable store + receive service, and the
    /// WCSession transport on iOS.
    public static func makeDefault(
        speechDescriptor: ModelDescriptor = PhoneAIModelCatalog.whisperLargeV3Turbo,
        textDescriptor: ModelDescriptor = PhoneAIModelCatalog.qwen3_1_7b_4bit,
        modelsRoot: URL? = nil
    ) throws -> SessionCoordinator {
        let root = try modelsRoot ?? PhoneAI.modelsRootDirectory()
        let store = SQLiteArchiveStore()

        // Ingest→enqueue seam: fires once per fresh durable chunk, inside
        // the receive path after registry insert and before the ack. A
        // fresh enqueue also fires the drain relay (bound to the
        // coordinator below) so foreground-arriving work drains promptly
        // instead of waiting for the next lifecycle event (R1-7).
        let drainKick = DrainKickRelay()
        let receiveService = PhoneReceiveService(archiveStore: store) { metadata in
            do {
                if try await store.hasAnalysisJob(kind: .transcription, chunkID: metadata.id) == false {
                    try await store.enqueueAnalysisJob(AnalysisJob(kind: .transcription, chunkID: metadata.id))
                    drainKick.fire()
                }
            } catch {
                await store.record(DiagnosticsEvent(
                    subsystem: .lifecycle, severity: .error,
                    name: "integration.enqueue_failed",
                    payload: ["chunk_id": metadata.id.uuidString]
                ))
            }
        }

        let gate = ModelExecutionGate()
        let diagnostics: @Sendable (DiagnosticsEvent) -> Void = { event in
            Task { await store.record(event) }
        }
        let transcriber = try PhoneAI.makeSpeechAdapter(
            descriptor: speechDescriptor, modelsRoot: root, gate: gate, diagnostics: diagnostics
        )
        let intelligence = try PhoneAI.makeTextAdapter(
            descriptor: textDescriptor, modelsRoot: root, gate: gate, diagnostics: diagnostics
        )
        let coordinator = SessionCoordinator(
            receiveService: receiveService,
            store: store,
            transcriber: transcriber,
            intelligence: intelligence
        )
        // Late-bind the kick — the receive hook is constructed before the
        // coordinator exists. A fired kick schedules one bounded drain
        // (coalesced with any pass already running). A kick dropped before
        // binding is harmless: `activate()` drains regardless.
        drainKick.handler = { [weak coordinator] in coordinator?.kickProcessing() }
        return coordinator
    }

    /// Injectable init for alternate stores/transports. The receive service
    /// must be constructed with its `onChunkStored` hook bound (or the
    /// caller must enqueue transcriptions itself).
    public init(
        receiveService: PhoneReceiveService,
        store: SQLiteArchiveStore,
        transcriber: SpeechTranscriptionAdapter,
        intelligence: TextIntelligenceAdapter
    ) {
        self.receiveService = receiveService
        self.store = store
        self.transcriber = transcriber
        self.intelligence = intelligence
        self.runner = AnalysisJobRunner(dependencies: .init(
            archive: store,
            transcriber: transcriber,
            intelligence: intelligence,
            audioFileResolver: { [store] metadata in
                try? await store.audioFileURL(chunkID: metadata.id)
            },
            chunkMetadataResolver: { [store] id in
                try? await store.chunkMetadata(id: id)
            },
            diagnostics: { [store] event in
                Task { await store.record(event) }
            }
        ))
        #if os(iOS) && canImport(WatchConnectivity)
        self.transport = WatchConnectivityReceiveTransport(receiveService: receiveService)
        #endif
    }

    // MARK: - Lifecycle

    /// Prepares durable state, activates WCSession (iOS), flushes pending
    /// deletion propagation, reconciles missed enqueues, then drains the
    /// queue. Idempotent — safe to call on every foreground.
    public func activate() async {
        #if os(iOS) && canImport(UIKit)
        _ = memoryWarningToken // bind the memory-warning observer once (lazy)
        #endif
        do {
            try await receiveService.prepare()
        } catch {
            await emit(.error, "integration.prepare_failed", ["error": errorClass(error)])
            return
        }
        #if os(iOS) && canImport(WatchConnectivity)
        _ = transport.activate()
        transport.flushDeletionIntents()
        #endif
        await reconcilePendingTranscriptions()
        await retryTransientFailures()
        scheduleDrain()
    }

    /// Failed jobs are usually transient here (model not installed yet,
    /// inference attempted while backgrounded, memory pressure). Requeue
    /// those under the attempt cap so they finish without a manual step;
    /// a job that keeps failing stops after `maxAutomaticAttempts`.
    public func retryTransientFailures() async {
        guard let failed = try? await store.analysisJobs(state: .failed) else { return }
        for job in failed where job.attemptCount < Self.maxAutomaticAttempts {
            var revived = job
            revived.state = .queued
            revived.updatedAt = Date()
            try? await store.updateAnalysisJob(revived)
        }
    }

    /// Stops the drain loop cooperatively (in-flight job completes; queued
    /// jobs persist for the next pass). Reserved for deliberate,
    /// process-lifetime shutdown (app teardown / account-reset class
    /// events) — the runner's `cancelled` flag is never reset, so this must
    /// NOT be used for routine events like a `BGProcessingTask` expiration
    /// (Task cancellation covers those; see `BackgroundAnalysisScheduler`).
    public func cancelProcessing() async {
        await runner.cancel()
    }

    /// Memory-pressure relief (R1-4): unloads BOTH engines through the
    /// shared execution gate — each unload waits out any in-flight
    /// inference, so it can never race a running job — and the engines
    /// lazily reload on their next `load`. Bound to
    /// `UIApplication.didReceiveMemoryWarningNotification` on iOS; other
    /// embedders can call it directly from their own pressure seam.
    /// Job outcomes are unaffected — only residency drops.
    public func releaseModelMemory() async {
        await transcriber.unloadEngine()
        await intelligence.unloadEngine()
        await emit(.warning, "integration.models_unloaded", ["reason": "memory_pressure"])
    }

    // MARK: - Ingest (data-path seam)

    /// Data-delivery seam (non-WC ingest): durable store → enqueue.
    /// The WC file path lands through `PhoneReceiveService` directly and
    /// reaches the same enqueue via the `onChunkStored` hook.
    public func ingestChunk(
        data: Data,
        metadata: AudioChunkMetadata
    ) async throws -> TransferAcknowledgment {
        try await receiveService.storeReceivedChunk(data: data, metadata: metadata)
    }

    /// File-delivery seam for phone-local capture: feeds the exact same
    /// `PhoneReceiveService.ingestReceivedFile` pipeline as WatchConnectivity
    /// (tombstone check → dedup → SHA-256 verification → atomic move into
    /// `RecorderArchive/chunks/` → SQLite registration → `onChunkStored`
    /// transcription enqueue + drain kick) and notifies live UI observers.
    public func ingestLocalChunkFile(
        at url: URL,
        metadata: AudioChunkMetadata
    ) async throws -> TransferAcknowledgment {
        let ack = try await receiveService.ingestReceivedFile(at: url, metadata: metadata)
        notifyChunkDidArrive(sessionID: metadata.sessionID)
        return ack
    }

    /// Persists a phone-local `RecordingSession` snapshot into the shared
    /// archive store and notifies live UI observers with `source: "phone"`.
    public func recordLocalSession(_ session: RecordingSession) async {
        do {
            try await store.upsertSession(session)
            notifyLocalSessionDidChange(session)
        } catch {
            await emit(.error, "integration.local_session_upsert_failed", [
                "session_id": session.id.uuidString,
                "error": errorClass(error)
            ])
        }
    }

    private nonisolated func notifyChunkDidArrive(sessionID: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: RecorderLiveNotifications.chunkDidArrive,
                object: nil,
                userInfo: ["sessionID": sessionID]
            )
        }
    }

    private nonisolated func notifyLocalSessionDidChange(_ session: RecordingSession) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: RecorderLiveNotifications.sessionDidChange,
                object: nil,
                userInfo: ["session": session, "source": "phone"]
            )
        }
    }

    /// Ask the pipeline to make progress soon. Coalesced: repeated kicks
    /// fold into at most one extra pass after the current one. Nonisolated
    /// so UI/BG callers can fire without awaiting.
    public nonisolated func kickProcessing() {
        Task { await self.scheduleDrain() }
    }

    // MARK: - Analysis pipeline

    /// One bounded pass: drain transcription jobs → regroup every session
    /// that gained segments or still holds ungrouped ones → drain the
    /// intelligence jobs that regrouping enqueued.
    /// Serialized via `acquireDrainSlot()` so concurrent callers (manual tap,
    /// automatic chunk kick, BGProcessingTask) never interleave or unload an
    /// engine while another pass is actively using it.
    public func processAnalysisQueue(maxJobsPerKind: Int = 24) async -> DrainSummary {
        await acquireDrainSlot()
        defer { releaseDrainSlot() }
        if Task.isCancelled { return DrainSummary() }

        var summary = DrainSummary()

        // Phase 1 — transcription drain; track which sessions gained output.
        var dirtySessions = Set<UUID>()
        let speechReady = await transcriber.readiness() == .ready
        while speechReady, summary.transcriptionJobs < maxJobsPerKind, !Task.isCancelled {
            let job: AnalysisJob?
            do {
                job = try await runner.runNextQueuedJob(kind: .transcription)
            } catch {
                await emit(.error, "integration.drain_error", ["kind": "transcription", "error": errorClass(error)])
                break
            }
            guard let job else { break }
            summary.transcriptionJobs += 1
            if job.state == .succeeded, let chunkID = job.chunkID,
               let metadata = try? await store.chunkMetadata(id: chunkID) {
                dirtySessions.insert(metadata.sessionID)
            }
            notifyAnalysisDidChange()
        }

        // Phase boundary (R1-4): the speech engine's work this pass is
        // done — release its residency before any text-model work (regroup
        // boundary reviews + the intelligence drain) so both models are
        // never co-resident. The unload is gate-serialized (waits out any
        // in-flight inference); the engine lazily reloads on next use.
        await transcriber.unloadEngine()

        // Phases 2–3 need the GPU-backed text model; when it isn't allowed
        // (app backgrounded) they run on the next foreground pass.
        guard await allowsTextModel() else {
            await emit(.info, "integration.drain_completed", [
                "transcription_jobs": "\(summary.transcriptionJobs)",
                "text_phases": "deferred_background",
            ])
            return summary
        }

        // Phase 2 — regroup dirty sessions + any session holding ungrouped
        // segments (crash-convergence: a regroup missed by an earlier pass is
        // always found again).
        var regroupSet = dirtySessions
        if let ungrouped = try? await store.sessionIDsWithUngroupedSegments() {
            regroupSet.formUnion(ungrouped)
        }
        for sessionID in regroupSet where !Task.isCancelled {
            do {
                let enqueued = try await regroup(sessionID: sessionID)
                summary.regroupedSessions += 1
                summary.enqueuedIntelligence += enqueued
                notifyAnalysisDidChange()
            } catch {
                await emit(.error, "integration.regroup_error", [
                    "session_id": sessionID.uuidString, "error": errorClass(error),
                ])
            }
        }

        // Phase 3 — intelligence drain (includes jobs enqueued in phase 2).
        let textReady = await intelligence.readiness() == .ready
        while textReady, summary.intelligenceJobs < maxJobsPerKind, !Task.isCancelled {
            let job: AnalysisJob?
            do {
                job = try await runner.runNextQueuedJob(kind: .intelligence)
            } catch {
                await emit(.error, "integration.drain_error", ["kind": "intelligence", "error": errorClass(error)])
                break
            }
            guard job != nil else { break }
            summary.intelligenceJobs += 1
            notifyAnalysisDidChange()
        }

        // Pass end (R1-4): release the text engine's residency too — a
        // following pass's transcription phase then starts with no model
        // resident, keeping peak residency at one engine across passes.
        await intelligence.unloadEngine()

        await emit(.info, "integration.drain_completed", [
            "transcription_jobs": "\(summary.transcriptionJobs)",
            "intelligence_jobs": "\(summary.intelligenceJobs)",
            "regrouped_sessions": "\(summary.regroupedSessions)",
            "enqueued_intelligence": "\(summary.enqueuedIntelligence)",
        ])
        return summary
    }

    /// Manual user-triggered pass ("Process now"): reconciles any stored clips
    /// missing jobs, requeues failed jobs without spawning a competing drain
    /// task, then runs a serialized drain and notifies listeners.
    public func runManualProcessing(maxJobsPerKind: Int = 24) async -> DrainSummary {
        await reconcilePendingTranscriptions()
        _ = await requeueFailedJobs(kind: .transcription, triggerDrain: false)
        _ = await requeueFailedJobs(kind: .intelligence, triggerDrain: false)
        let summary = await processAnalysisQueue(maxJobsPerKind: maxJobsPerKind)
        notifyAnalysisDidChange()
        return summary
    }

    private func acquireDrainSlot() async {
        if !drainInFlight {
            drainInFlight = true
            return
        }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func releaseDrainSlot() {
        if !drainWaiters.isEmpty {
            let next = drainWaiters.removeFirst()
            next.resume()
        } else {
            drainInFlight = false
        }
    }

    private nonisolated func notifyAnalysisDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: RecorderLiveNotifications.analysisDidChange, object: nil)
        }
    }

    /// Re-derives groups for one session from ALL live segments (across
    /// chunk boundaries), reconciles against persisted groups by overlap,
    /// upserts, and enqueues metadata jobs for new/membership-changed
    /// groups. Persisted generated metadata stays verbatim; per-field user
    /// overrides are honored at read time by `effectiveMetadata` — regrouping
    /// never touches override rows.
    private func regroup(sessionID: UUID) async throws -> Int {
        let segments = try await store.transcriptSegments(sessionID: sessionID)
        let existing = try await store.conversationGroups(sessionID: sessionID)
        let proposals = try await intelligence.proposeConversationGroups(
            sessionID: sessionID, segments: segments
        )
        let plan = ConversationRegrouping.plan(proposals: proposals, existing: existing)
        for id in plan.disbandedIDs {
            try await store.disbandConversationGroup(conversationID: id)
        }
        for group in plan.upserts {
            try await store.upsertConversationGroup(group)
        }
        for conversationID in plan.intelligenceTargets {
            try await store.enqueueAnalysisJob(
                AnalysisJob(kind: .intelligence, conversationID: conversationID)
            )
        }
        return plan.intelligenceTargets.count
    }

    /// Restart/crash safety net: enqueues a transcription job for every
    /// stored chunk that has no job row in ANY state, and revives jobs the
    /// runner left `.cancelled` for still-live targets (e.g. a BG-task
    /// expiration cancelled the drain).
    public func reconcilePendingTranscriptions() async {
        do {
            let sessionIDs = Set(try await store.sessionIDsWithStoredChunks())
            for sessionID in sessionIDs {
                for chunk in await receiveService.receivedChunks(sessionID: sessionID) {
                    // Only stored (playable) chunks — expired/quarantined
                    // ones must not mint doomed jobs on every activate.
                    guard try await store.audioFileURL(chunkID: chunk.id) != nil else { continue }
                    if try await store.hasAnalysisJob(kind: .transcription, chunkID: chunk.id) == false {
                        try await store.enqueueAnalysisJob(
                            AnalysisJob(kind: .transcription, chunkID: chunk.id)
                        )
                    }
                }
            }
            // Cancelled jobs are not verdicts — a BG expiration or app kill
            // put them there. Requeue so the work isn't orphaned.
            for job in try await store.analysisJobs(state: .cancelled) {
                let targetAlive: Bool
                if let chunkID = job.chunkID {
                    // Playable file = still-live chunk (tombstoned and
                    // expired chunks return nil → not revived).
                    targetAlive = try await store.audioFileURL(chunkID: chunkID) != nil
                } else if let conversationID = job.conversationID {
                    targetAlive = try await store.transcriptSegments(conversationID: conversationID).isEmpty == false
                } else {
                    targetAlive = false
                }
                guard targetAlive else { continue }
                var revived = job
                revived.state = .queued
                revived.updatedAt = Date()
                try await store.updateAnalysisJob(revived)
            }
        } catch {
            await emit(.error, "integration.reconcile_error", ["error": errorClass(error)])
        }
    }

    /// Requeues `.failed` jobs of a kind — call after a model install makes
    /// the previously-failing input runnable. Bounded to explicit calls so a
    /// permanently-broken chunk can't spin; attempt history is preserved.
    public func requeueFailedJobs(kind: AnalysisJobKind, triggerDrain: Bool = true) async -> Int {
        guard let failed = try? await store.analysisJobs(state: .failed) else { return 0 }
        var requeued = 0
        for job in failed where job.kind == kind {
            var revived = job
            revived.state = .queued
            revived.updatedAt = Date()
            do {
                try await store.updateAnalysisJob(revived)
                requeued += 1
            } catch { break }
        }
        if triggerDrain && requeued > 0 { scheduleDrain() }
        return requeued
    }

    private func scheduleDrain() {
        guard !drainScheduled else {
            drainAgain = true
            return
        }
        drainScheduled = true
        Task {
            guard await self.canDrainNow() else {
                self.finishDeferredDrain()
                return
            }
            // Bounded passes self-continue while durable work remains
            // (R1-7): a mid-pass enqueue (kick → drainAgain) or a pass that
            // hit its per-kind cap must not strand queued jobs until the
            // next lifecycle event. A zero-progress pass stops regardless —
            // error paths leave jobs queued, and looping there would spin.
            var again = true
            while again {
                drainAgain = false
                let summary = await self.processAnalysisQueue()
                let ran = summary.transcriptionJobs + summary.intelligenceJobs
                let remaining = await self.queuedJobCount()
                again = self.drainAgain || (ran > 0 && remaining > 0)
            }
            drainScheduled = false
        }
    }

    private func finishDeferredDrain() {
        drainScheduled = false
        drainAgain = false
        onDeferredWork()
    }

    // MARK: - Deletion + lifecycle

    /// Records a user deletion, cascades tombstones, and immediately pushes
    /// the discard set to the watch outbox. Delayed deliveries of deleted
    /// ids are answered `.tombstoned` and never resurrect content.
    public func applyDeletion(_ intent: DeletionIntent) async throws {
        try await store.applyDeletionIntent(intent)
        flushDeletionIntents()
        // Deletion may orphan groups (segments removed) — regroup the
        // affected sessions on the next pass.
        scheduleDrain()
    }

    /// Pushes unpropagated deletion intents to the watch — call after
    /// deletions and on lifecycle transitions (activation/foreground).
    /// Nonisolated: the transport owns its own queueing.
    public nonisolated func flushDeletionIntents() {
        #if os(iOS) && canImport(WatchConnectivity)
        transport.flushDeletionIntents()
        #endif
    }

    // MARK: - Model installs

    public func installSpeechModel() async throws {
        try await transcriber.installModel()
    }
    public func installTextModel() async throws {
        try await intelligence.installModel()
    }
    public func cancelModelInstalls() async {
        await transcriber.cancelInstall()
        await intelligence.cancelInstall()
    }
    public func speechInstallSnapshots() async -> AsyncStream<ModelInstallSnapshot> {
        await transcriber.installSnapshots()
    }
    public func textInstallSnapshots() async -> AsyncStream<ModelInstallSnapshot> {
        await intelligence.installSnapshots()
    }
    public func speechInstallSnapshot() async -> ModelInstallSnapshot {
        await transcriber.installSnapshot()
    }
    public func textInstallSnapshot() async -> ModelInstallSnapshot {
        await intelligence.installSnapshot()
    }

    // MARK: - Status/read seam for the app shell

    public nonisolated var speechEngineIdentifier: String { transcriber.engineIdentifier }
    public nonisolated var textEngineIdentifier: String { intelligence.engineIdentifier }

    public func transcriptionReadiness() async -> ModelReadinessState {
        await transcriber.readiness()
    }
    public func intelligenceReadiness() async -> ModelReadinessState {
        await intelligence.readiness()
    }

    /// The store through the promoted protocol — the app's read/write seam
    /// for sessions, groups, effective metadata, overrides, search,
    /// retention, jobs, and diagnostics. Nonisolated because `store` is a
    /// thread-safe actor constant; callers never block on coordinator work
    /// just to look up audio files or read the archive.
    public nonisolated func archiveStore() -> any ExtendedArchiveStoreProtocol {
        store
    }

    public nonisolated func receivedChunks(sessionID: UUID) async -> [AudioChunkMetadata] {
        await receiveService.receivedChunks(sessionID: sessionID)
    }

    /// Queued analysis work remaining — the BG scheduler uses this to decide
    /// whether another OS window is needed after its pass.
    public func queuedJobCount() async -> Int {
        (try? await store.analysisJobs(state: .queued).count) ?? 0
    }

    /// Public diagnostics sink for integration-layer callers (BG scheduler).
    public func recordDiagnostic(name: String, payload: [String: String]) async {
        await emit(.warning, name, payload)
    }

    /// Structured non-content diagnostics for Gate A (counts, states, error
    /// classes only — never audio or transcript payloads).
    public func diagnosticsReport(limit: Int = 500) async throws -> DiagnosticsReport {
        var system = utsname()
        uname(&system)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return try await store.diagnosticsReport(deviceModel: model, osVersion: osVersion, limit: limit)
    }

    // MARK: - Diagnostics

    private func emit(
        _ severity: DiagnosticsSeverity,
        _ name: String,
        _ payload: [String: String]
    ) async {
        await store.record(DiagnosticsEvent(subsystem: .lifecycle, severity: severity, name: name, payload: payload))
    }

    private func errorClass(_ error: Error) -> String {
        String(describing: type(of: error))
    }
}

/// Late-bound drain trigger — the `onChunkStored` receive hook is built
/// before the coordinator exists, so `makeDefault` binds the target after
/// init. Firing is synchronous and cheap (spawns one coalesced drain Task).
private final class DrainKickRelay: @unchecked Sendable {
    var handler: (@Sendable () -> Void)?
    func fire() { handler?() }
}

/// Owns a `NotificationCenter` observer registration and unregisters it on
/// deinit — lets the actor hold a registration without deinit isolation
/// concerns (`NotificationCenter` observers must be removed eventually).
private final class ObserverToken: @unchecked Sendable {
    private let observer: NSObjectProtocol
    init(_ observer: NSObjectProtocol) { self.observer = observer }
    deinit { NotificationCenter.default.removeObserver(observer) }
}
