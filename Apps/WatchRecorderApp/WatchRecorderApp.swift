import RecorderContracts
import SwiftUI
import WatchCapture
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

@main
struct WatchRecorderApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

/// Minimal wiring so the real capture + transfer services are manually
/// exercisable. Drives `stateUpdates()` into the UI, feeds app-lifecycle
/// transitions to the service's honest bookkeeping, and re-pumps the outbox
/// on activation. U1 owns the shipped interface later — this is the
/// exercise-the-real-path shell, not mocks.
@MainActor
final class RecorderModel: ObservableObject {
    @Published private(set) var session: RecordingSession?
    @Published private(set) var finalizedCount = 0
    @Published private(set) var awaitingAckCount = 0
    @Published private(set) var busy = false
    @Published var errorMessage: String?

    let diagnostics: WatchDiagnostics
    let transfer: WatchTransferService
    let capture: WatchCaptureService
    #if canImport(WatchConnectivity)
    private let sessionRelay = SessionSyncRelay()
    #endif

    init() {
        let diagnostics = WatchDiagnostics()
        self.diagnostics = diagnostics
        self.transfer = WatchTransferService(diagnostics: diagnostics)
        self.capture = WatchCaptureService(outbox: transfer, diagnostics: diagnostics)
        diagnostics.emit(.lifecycle, name: "app-init")
        Task { [transfer] in
            await transfer.activate()
        }
        Task { [capture] in
            await self.refreshStatic()
            for await update in capture.stateUpdates() {
                self.session = update
                // I1 session truth: relay every snapshot to the phone mirror.
                #if canImport(WatchConnectivity)
                sessionRelay.send(update)
                #endif
                await self.refreshCounts()
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { [capture] in await capture.appDidBecomeActive() }
            Task { [transfer] in await transfer.activate() }
        case .inactive:
            Task { [capture] in await capture.appWillResignActive() }
        case .background:
            Task { [capture] in await capture.appDidEnterBackground() }
        @unknown default:
            break
        }
    }

    func start() { run { try await self.capture.startSession() } }
    func pause() { run { try await self.capture.pauseSession() } }
    func resume() { run { try await self.capture.resumeSession() } }
    func stop() { run { try await self.capture.stopSession() } }

    private func run(_ action: @escaping () async throws -> RecordingSession) {
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await action()
            } catch {
                errorMessage = String(describing: error)
                diagnostics.emit(.lifecycle, name: "control-failed", severity: .error,
                                 payload: ["error": "\(error)"])
            }
            busy = false
        }
    }

    private func refreshStatic() async {
        session = await capture.currentSession()
        await refreshCounts()
    }

    private func refreshCounts() async {
        guard let id = session?.id else {
            finalizedCount = 0
            awaitingAckCount = 0
            return
        }
        finalizedCount = await capture.finalizedChunks(sessionID: id).count
        awaitingAckCount = await transfer.chunksAwaitingAcknowledgment(sessionID: id).count
    }
}

#if canImport(WatchConnectivity)
/// I1 session-truth relay: forwards each `stateUpdates()` snapshot to the
/// paired phone as `applicationContext` — latest-value semantics match the
/// phone's sessions mirror (`upsertSession`). Shares the `WCSession` that
/// `WatchTransferService` activates; sends are dropped until activation and
/// payloads are `["type": "session", "session": Data(JSON)]`.
final class SessionSyncRelay {
    private let encoder = JSONEncoder()

    func send(_ session: RecordingSession) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              let data = try? encoder.encode(session)
        else { return }
        try? WCSession.default.updateApplicationContext([
            "type": "session",
            "session": data,
        ])
    }
}
#endif
