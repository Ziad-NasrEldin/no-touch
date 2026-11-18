import Foundation
import RecorderContracts
import PhoneAI
import PhoneStorage
#if canImport(Darwin)
import Darwin
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

    #if os(iOS) && canImport(WatchConnectivity)
    private let transport: WatchConnectivityReceiveTransport
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
        // the receive path after registry insert and before the ack.
        let receiveService = PhoneReceiveService(archiveStore: store) { metadata in
            do {
                if try await store.hasAnalysisJob(kind: .transcription, chunkID: metadata.id) == false {
                    try await store.enqueueAnalysisJob(AnalysisJob(kind: .transcription, chunkID: metadata.id))
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
        return SessionCoordinator(
            receiveService: receiveService,
            store: store,
            transcriber: transcriber,
            intelligence: intelligence
        )
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
        scheduleDrain()
    }

    /// Stops the drain loop cooperatively (in-flight job completes; queued
    /// jobs persist for the next pass). Call on a deliberate shutdown only —
    /// the runner's cancelled flag is process-lifetime.
    public func cancelProcessing() async {
        await runner.cancel()
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
    public func processAnalysisQueue(maxJobsPerKind: Int = 24) async -> DrainSummary {
        var summary = DrainSummary()

        // Phase 1 — transcription drain; track which sessions gained output.
        var dirtySessions = Set<UUID>()
        while summary.transcriptionJobs < maxJobsPerKind {
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
        }

        // Phase 2 — regroup dirty sessions + any session holding ungrouped
        // segments (crash-convergence: a regroup missed by an earlier pass is
        // always found again).
        var regroupSet = dirtySessions
        if let ungrouped = try? await store.sessionIDsWithUngroupedSegments() {
            regroupSet.formUnion(ungrouped)
        }
        for sessionID in regroupSet {
            do {
                let enqueued = try await regroup(sessionID: sessionID)
                summary.regroupedSessions += 1
                summary.enqueuedIntelligence += enqueued
            } catch {
                await emit(.error, "integration.regroup_error", [
                    "session_id": sessionID.uuidString, "error": errorClass(error),
                ])
            }
        }

        // Phase 3 — intelligence drain (includes jobs enqueued in phase 2).
        while summary.intelligenceJobs < maxJobsPerKind {
            let job: AnalysisJob?
            do {
                job = try await runner.runNextQueuedJob(kind: .intelligence)
            } catch {
                await emit(.error, "integration.drain_error", ["kind": "intelligence", "error": errorClass(error)])
                break
            }
            guard job != nil else { break }
            summary.intelligenceJobs += 1
        }

        await emit(.info, "integration.drain_completed", [
            "transcription_jobs": "\(summary.transcriptionJobs)",
            "intelligence_jobs": "\(summary.intelligenceJobs)",
            "regrouped_sessions": "\(summary.regroupedSessions)",
            "enqueued_intelligence": "\(summary.enqueuedIntelligence)",
        ])
        return summary
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
    public func requeueFailedJobs(kind: AnalysisJobKind) async -> Int {
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
        if requeued > 0 { scheduleDrain() }
        return requeued
    }

    private func scheduleDrain() {
        guard !drainScheduled else {
            drainAgain = true
            return
        }
        drainScheduled = true
        Task {
            repeat {
                drainAgain = false
                _ = await self.processAnalysisQueue()
            } while self.drainAgain
            drainScheduled = false
        }
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
    public func speechInstallSnapshots() async -> AsyncStream<ModelInstallSnapshot> {
        await transcriber.installSnapshots()
    }
    public func textInstallSnapshots() async -> AsyncStream<ModelInstallSnapshot> {
        await intelligence.installSnapshots()
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
    /// retention, jobs, and diagnostics.
    public func archiveStore() -> any ExtendedArchiveStoreProtocol {
        store
    }

    public func receivedChunks(sessionID: UUID) async -> [AudioChunkMetadata] {
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
