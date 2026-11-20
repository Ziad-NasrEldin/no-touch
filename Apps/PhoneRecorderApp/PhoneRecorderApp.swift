import SwiftUI
import UIKit
import RecorderContracts
import PhoneAI
import PhoneIntegration
import PhoneStorage

/// App-shell model: owns the integration coordinator, BGProcessingTask
/// registration, model-install progress, manual processing feedback, and live
/// counts read from the archive through `ExtendedArchiveStoreProtocol`.
@MainActor
final class PhoneRecorderModel: ObservableObject {
    let coordinator: SessionCoordinator?
    #if os(iOS)
    private let bgScheduler: BackgroundAnalysisScheduler?
    #endif

    @Published var speechReadiness: ModelReadinessState = .notInstalled
    @Published var textReadiness: ModelReadinessState = .notInstalled
    @Published var speechProgress: Double = 0
    @Published var textProgress: Double = 0
    @Published var speechDownloadedBytes: Int64 = 0
    @Published var speechExpectedBytes: Int64?
    @Published var textDownloadedBytes: Int64 = 0
    @Published var textExpectedBytes: Int64?
    @Published var speechFailureReason: String?
    @Published var textFailureReason: String?

    @Published var queuedJobs = 0
    @Published var failedJobs = 0
    @Published var sessionCount = 0
    @Published var chunkCount = 0
    @Published var groupCount = 0
    @Published var engineLabel = ""

    @Published var isInstalling = false
    @Published var installStage: String?
    @Published var isProcessing = false
    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published var recentJobError: String?
    @Published var lastDrain = ""

    let live: LiveRecordingStatus
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []

    var allModelsReady: Bool {
        speechReadiness == .ready && textReadiness == .ready
    }

    init() {
        if let coordinator = try? SessionCoordinator.makeDefault() {
            self.coordinator = coordinator
            live = LiveRecordingStatus(coordinator: coordinator)
            #if os(iOS)
            let scheduler = BackgroundAnalysisScheduler(coordinator: coordinator)
            scheduler.register()
            bgScheduler = scheduler
            // Run inference only while the app is in the foreground; when a
            // watch clip wakes the app in the background, hand the work to a
            // BGProcessingTask instead (the OS runs it when it can).
            Task {
                await coordinator.setDrainPolicy(
                    // Foreground, or kept awake while the watch records.
                    canDrainNow: {
                        await MainActor.run {
                            UIApplication.shared.applicationState != .background || BackgroundKeepAlive.isRunning
                        }
                    },
                    onDeferredWork: { scheduler.schedule() },
                    // Text model needs the GPU → foreground only.
                    allowsTextModel: {
                        await MainActor.run { UIApplication.shared.applicationState != .background }
                    }
                )
            }
            #endif
            engineLabel = "speech=\(coordinator.speechEngineIdentifier) text=\(coordinator.textEngineIdentifier)"
        } else {
            coordinator = nil
            live = LiveRecordingStatus(coordinator: nil)
            #if os(iOS)
            bgScheduler = nil
            #endif
            lastError = "Coordinator bootstrap failed (models root unavailable)."
        }

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: RecorderLiveNotifications.analysisDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })
        notificationObservers.append(center.addObserver(
            forName: RecorderLiveNotifications.chunkDidArrive, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })

        Task { await observeInstalls() }
        Task { [weak self] in
            await self?.coordinator?.activate()
            await self?.refresh()
        }
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeInstalls() async {
        guard let coordinator else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await snapshot in await coordinator.speechInstallSnapshots() {
                    await MainActor.run {
                        self?.applySpeechSnapshot(snapshot)
                    }
                }
            }
            group.addTask { [weak self] in
                for await snapshot in await coordinator.textInstallSnapshots() {
                    await MainActor.run {
                        self?.applyTextSnapshot(snapshot)
                    }
                }
            }
        }
    }

    private func applySpeechSnapshot(_ snapshot: ModelInstallSnapshot) {
        speechReadiness = snapshot.state
        speechProgress = snapshot.progress
        speechDownloadedBytes = snapshot.downloadedBytes
        speechExpectedBytes = snapshot.expectedBytes
        speechFailureReason = snapshot.failureReason
    }

    private func applyTextSnapshot(_ snapshot: ModelInstallSnapshot) {
        textReadiness = snapshot.state
        textProgress = snapshot.progress
        textDownloadedBytes = snapshot.downloadedBytes
        textExpectedBytes = snapshot.expectedBytes
        textFailureReason = snapshot.failureReason
    }

    func refresh() async {
        guard let coordinator else { return }
        let store = coordinator.archiveStore()
        applySpeechSnapshot(await coordinator.speechInstallSnapshot())
        applyTextSnapshot(await coordinator.textInstallSnapshot())
        speechReadiness = await coordinator.transcriptionReadiness()
        textReadiness = await coordinator.intelligenceReadiness()

        let queued = (try? await store.analysisJobs(state: .queued)) ?? []
        let failed = (try? await store.analysisJobs(state: .failed)) ?? []
        queuedJobs = queued.count
        failedJobs = failed.count
        recentJobError = failed.sorted { $0.updatedAt > $1.updatedAt }.first?.lastError

        let sessions = (try? await store.sessions()) ?? []
        var allSessionIDs = Set(sessions.map(\.id))
        if let chunkSessions = try? await store.sessionIDsWithStoredChunks() {
            allSessionIDs.formUnion(chunkSessions)
        }
        sessionCount = allSessionIDs.count

        var chunksTotal = 0
        var groupsTotal = 0
        for sessionID in allSessionIDs {
            chunksTotal += await coordinator.receivedChunks(sessionID: sessionID).count
            groupsTotal += ((try? await store.conversationGroups(sessionID: sessionID)) ?? []).count
        }
        chunkCount = chunksTotal
        groupCount = groupsTotal
    }

    func installModels() {
        guard !isInstalling else { return }
        guard let coordinator else {
            lastError = "Pipeline coordinator is unavailable."
            return
        }
        lastError = nil

        if allModelsReady {
            statusMessage = "Both models are already installed and ready."
            Task { await refresh() }
            return
        }

        isInstalling = true
        installStage = "Preparing model download…"
        statusMessage = "Starting model installation…"

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isInstalling = false
                self.installStage = nil
            }
            do {
                if await coordinator.transcriptionReadiness() != .ready {
                    self.installStage = "Downloading speech model (1/2)…"
                    try await coordinator.installSpeechModel()
                }
                if await coordinator.intelligenceReadiness() != .ready {
                    self.installStage = "Downloading text model (2/2)…"
                    try await coordinator.installTextModel()
                }
                // Jobs that failed pre-install (modelNotReady) become runnable.
                let retriedTranscription = await coordinator.requeueFailedJobs(kind: .transcription, triggerDrain: false)
                let retriedIntelligence = await coordinator.requeueFailedJobs(kind: .intelligence, triggerDrain: false)
                await self.refresh()
                if retriedTranscription + retriedIntelligence > 0 || self.queuedJobs > 0 {
                    self.statusMessage = "Models installed. Processing queued recordings…"
                    coordinator.kickProcessing()
                } else {
                    self.statusMessage = "Both models installed and verified."
                }
            } catch is CancellationError {
                self.statusMessage = "Model installation cancelled. Partial files kept to resume."
            } catch {
                self.lastError = "Install failed: \(error.localizedDescription)"
                self.statusMessage = nil
            }
            await self.refresh()
        }
    }

    func cancelInstall() {
        guard isInstalling, let coordinator else { return }
        statusMessage = "Cancelling download…"
        Task { await coordinator.cancelModelInstalls() }
    }

    func processNow() {
        guard !isProcessing else { return }
        guard let coordinator else {
            lastError = "Pipeline coordinator is unavailable."
            return
        }

        isProcessing = true
        lastError = nil
        recentJobError = nil
        statusMessage = "Checking recordings and queue…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }

            await coordinator.reconcilePendingTranscriptions()
            await self.refresh()

            let speech = await coordinator.transcriptionReadiness()
            let text = await coordinator.intelligenceReadiness()

            if speech != .ready {
                if self.chunkCount == 0 && self.queuedJobs == 0 && self.failedJobs == 0 {
                    self.statusMessage = "No recordings in archive yet. Install models on Wi-Fi when ready."
                } else {
                    self.statusMessage = "Speech model is \(Self.readinessLabel(speech)). Tap Install models first."
                }
                self.lastDrain = self.statusMessage ?? ""
                return
            }

            self.statusMessage = "Processing recordings…"
            let summary = await coordinator.runManualProcessing()
            await self.refresh()

            let message: String
            let totalWork = summary.transcriptionJobs + summary.regroupedSessions + summary.intelligenceJobs
            if totalWork > 0 {
                var parts: [String] = []
                if summary.transcriptionJobs > 0 {
                    parts.append("\(summary.transcriptionJobs) clip\(summary.transcriptionJobs == 1 ? "" : "s") transcribed")
                }
                if summary.regroupedSessions > 0 {
                    parts.append("\(summary.regroupedSessions) session\(summary.regroupedSessions == 1 ? "" : "s") grouped")
                }
                if summary.intelligenceJobs > 0 {
                    parts.append("\(summary.intelligenceJobs) summary\(summary.intelligenceJobs == 1 ? "" : " jobs") updated")
                }
                var combined = "Done: " + parts.joined(separator: ", ") + "."
                if text != .ready {
                    combined += " Install the text model for titles & summaries."
                }
                if self.failedJobs > 0 {
                    combined += " \(self.failedJobs) job\(self.failedJobs == 1 ? "" : "s") failed."
                }
                message = combined
            } else if self.failedJobs > 0 {
                message = "0 processed — \(self.failedJobs) job\(self.failedJobs == 1 ? "" : "s") failed. See error below."
            } else if self.chunkCount == 0 {
                message = "No recordings in archive to process yet."
            } else if text != .ready {
                message = "All clips are transcribed. Install the text model for titles & summaries."
            } else {
                message = "Everything is up to date — no pending clips to process."
            }

            self.statusMessage = message
            self.lastDrain = message
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { [weak self] in
                await self?.coordinator?.activate()
                await self?.live.reloadFromArchive()
                await self?.refresh()
            }
        case .background:
            #if os(iOS)
            bgScheduler?.schedule()
            #endif
            coordinator?.flushDeletionIntents()
        default:
            break
        }
    }

    static func readinessLabel(_ state: ModelReadinessState) -> String {
        switch state {
        case .notInstalled: return "Not installed"
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}

@main
struct PhoneRecorderApp: App {
    @StateObject private var model = PhoneRecorderModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                RecordingsView(model: model)
                    .tabItem { Label("Recordings", systemImage: "waveform") }
                NavigationStack { ContentView(model: model) }
                    .tabItem { Label("Status", systemImage: "gearshape") }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
