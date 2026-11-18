import Foundation

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

/// iOS background drain of the durable analysis queue via `BGProcessingTask`.
///
/// This is the "transfers and analysis may be delayed by OS scheduling"
/// path the spec allows: the system decides when the task actually runs
/// (typically while charging, on Wi-Fi, or in maintenance windows), so this
/// supplements — never replaces — foreground draining on `.active`.
///
/// Honest bounds:
/// - `requiresExternalPower = false`, `requiresNetworkConnectivity = false`:
///   inference is on-device; the OS may still defer heavy work on battery.
/// - Each drain pass is bounded (`maxJobsPerKind`); the loop exits when a
///   pass runs nothing. Work left over reschedules a later OS window.
/// - Expiration cancels the drain Task; the in-flight job lands
///   `.cancelled` and is revived by `reconcilePendingTranscriptions` on the
///   next pass, so work is never orphaned.
public final class BackgroundAnalysisScheduler: @unchecked Sendable {
    public static let taskIdentifier = "com.placeholder.PhoneRecorder.processing"

    private let coordinator: SessionCoordinator

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    /// Registers the launch handler. MUST be called during app launch —
    /// BGTaskScheduler asserts if registration happens after the app has
    /// finished launching.
    public func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGProcessingTask, let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(task)
        }
    }

    /// Submits (or refreshes) the processing request. `earliestBeginDate`
    /// nil means "as soon as feasible" — the OS still decides. Call when
    /// entering the background, and after installs leave runnable work.
    public func schedule(earliestBeginDate: Date? = nil) {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Task {
                await coordinator.recordDiagnostic(
                    name: "integration.bg_schedule_failed",
                    payload: ["error": "\(type(of: error))"]
                )
            }
        }
    }

    private func handle(_ task: BGProcessingTask) {
        // `setTaskCompleted` is documented callable from any thread; BGTask
        // is not Sendable so box it for the `sending` Task closure.
        let boxed = UncheckedSendableBox(task)
        let drain = Task { [weak self, boxed] in
            let task = boxed.value
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            var ran = 0
            repeat {
                let summary = await coordinator.processAnalysisQueue(maxJobsPerKind: 24)
                ran = summary.transcriptionJobs + summary.intelligenceJobs
            } while ran > 0 && !Task.isCancelled

            let remaining = await coordinator.queuedJobCount()
            task.setTaskCompleted(success: !Task.isCancelled)
            if remaining > 0 {
                // Work remains — ask the OS for another window.
                self.schedule(earliestBeginDate: Date().addingTimeInterval(15 * 60))
            }
        }
        task.expirationHandler = { [weak self] in
            drain.cancel()
            Task { await self?.coordinator.cancelProcessing() }
        }
    }
}

/// Sendable box for values that are thread-safe but lack `Sendable`
/// conformance — `BGTask` callbacks are documented thread-safe.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
