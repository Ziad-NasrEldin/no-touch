import SwiftUI
import RecorderContracts
import PhoneIntegration

/// Real app-shell model (I1): owns the integration coordinator, the
/// BGProcessingTask registration, model-install progress, and live counts
/// read from the archive through `ExtendedArchiveStoreProtocol`.
/// U1 owns the real product UI; this shell exercises the real pipeline.
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
    @Published var queuedJobs = 0
    @Published var failedJobs = 0
    @Published var sessionCount = 0
    @Published var groupCount = 0
    @Published var engineLabel = ""
    @Published var lastError: String?
    @Published var lastDrain = ""

    init() {
        if let coordinator = try? SessionCoordinator.makeDefault() {
            self.coordinator = coordinator
            #if os(iOS)
            bgScheduler = BackgroundAnalysisScheduler(coordinator: coordinator)
            bgScheduler?.register()
            #endif
            engineLabel = "speech=\(coordinator.speechEngineIdentifier) text=\(coordinator.textEngineIdentifier)"
        } else {
            coordinator = nil
            #if os(iOS)
            bgScheduler = nil
            #endif
            lastError = "coordinator bootstrap failed (models root unavailable)"
        }
        Task { await observeInstalls() }
        Task { [weak self] in
            await self?.coordinator?.activate()
            await self?.refresh()
        }
    }

    private func observeInstalls() async {
        guard let coordinator else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await snapshot in await coordinator.speechInstallSnapshots() {
                    await MainActor.run {
                        self?.speechReadiness = snapshot.state
                        self?.speechProgress = snapshot.progress
                    }
                }
            }
            group.addTask { [weak self] in
                for await snapshot in await coordinator.textInstallSnapshots() {
                    await MainActor.run {
                        self?.textReadiness = snapshot.state
                        self?.textProgress = snapshot.progress
                    }
                }
            }
        }
    }

    func refresh() async {
        guard let coordinator, let store = await storeOf(coordinator) else { return }
        speechReadiness = await coordinator.transcriptionReadiness()
        textReadiness = await coordinator.intelligenceReadiness()
        queuedJobs = (try? await store.analysisJobs(state: .queued).count) ?? 0
        failedJobs = (try? await store.analysisJobs(state: .failed).count) ?? 0
        let sessions = (try? await store.sessions()) ?? []
        sessionCount = sessions.count
        var groups = 0
        for session in sessions {
            groups += ((try? await store.conversationGroups(sessionID: session.id)) ?? []).count
        }
        groupCount = groups
    }

    private func storeOf(_ coordinator: SessionCoordinator) async -> (any ExtendedArchiveStoreProtocol)? {
        await coordinator.archiveStore()
    }

    func installModels() {
        Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            do {
                if await coordinator.transcriptionReadiness() != .ready {
                    try await coordinator.installSpeechModel()
                }
                if await coordinator.intelligenceReadiness() != .ready {
                    try await coordinator.installTextModel()
                }
                // Jobs that failed pre-install (modelNotReady) become runnable.
                let retriedTranscription = await coordinator.requeueFailedJobs(kind: .transcription)
                let retriedIntelligence = await coordinator.requeueFailedJobs(kind: .intelligence)
                if retriedTranscription + retriedIntelligence > 0 { coordinator.kickProcessing() }
            } catch {
                self?.lastError = "install failed: \(error)"
            }
            await self?.refresh()
        }
    }

    func processNow() {
        Task { [weak self] in
            _ = await self?.coordinator?.processAnalysisQueue()
            await self?.refresh()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { [weak self] in
                await self?.coordinator?.activate()
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
}

@main
struct PhoneRecorderApp: App {
    @StateObject private var model = PhoneRecorderModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
