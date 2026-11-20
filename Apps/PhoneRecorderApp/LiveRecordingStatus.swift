import SwiftUI
import ActivityKit
import RecorderContracts
import PhoneIntegration
import PhoneStorage

/// Tracks the watch's current recording session on the iPhone and mirrors it
/// into an in-app banner plus a Live Activity (Lock Screen + Dynamic Island).
///
/// Inputs: session snapshots and chunk arrivals posted by the WatchConnectivity
/// transport, plus a reload from the archive whenever the app becomes active.
/// iOS only lets an app *start* a Live Activity while it is in the foreground,
/// so a start that fails in the background is retried on the next foreground.
@MainActor
final class LiveRecordingStatus: ObservableObject {
    @Published private(set) var session: RecordingSession?
    @Published private(set) var clipCount = 0
    @Published private(set) var lastHeardAt: Date?

    private weak var coordinator: SessionCoordinator?
    private var observers: [NSObjectProtocol] = []
    /// ID of the Live Activity we own (activities are looked up by ID so
    /// the non-Sendable `Activity` never crosses isolation boundaries).
    private var activityID: String?
    private var activitySessionID: String?

    var isLive: Bool {
        guard let state = session?.state else { return false }
        return state == .recording || state == .paused || state == .interrupted
    }

    init(coordinator: SessionCoordinator?) {
        self.coordinator = coordinator
        if let existing = Activity<RecordingActivityAttributes>.activities.first {
            activityID = existing.id
            activitySessionID = existing.attributes.sessionID
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: RecorderLiveNotifications.sessionDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let snapshot = note.userInfo?["session"] as? RecordingSession else { return }
            Task { @MainActor in await self?.apply(snapshot) }
        })
        observers.append(center.addObserver(
            forName: RecorderLiveNotifications.chunkDidArrive, object: nil, queue: .main
        ) { [weak self] note in
            let sessionID = note.userInfo?["sessionID"] as? UUID
            Task { @MainActor in await self?.chunkArrived(sessionID: sessionID) }
        })
        Task { await reloadFromArchive() }
    }

    /// Picks up the newest session from the archive (e.g. after launch or
    /// returning to the foreground) and (re)starts the Live Activity.
    func reloadFromArchive() async {
        if let coordinator {
            let store = coordinator.archiveStore()
            let sessions = (try? await store.sessions()) ?? []
            guard let latest = sessions.max(by: {
                ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
            }) else { return }
            await apply(latest)
        }
    }

    private func apply(_ snapshot: RecordingSession) async {
        if session?.id != snapshot.id { clipCount = 0 }
        session = snapshot
        lastHeardAt = Date()
        if let coordinator {
            clipCount = await coordinator.receivedChunks(sessionID: snapshot.id).count
        }
        await syncActivity()
    }

    private func chunkArrived(sessionID: UUID?) async {
        lastHeardAt = Date()
        if let coordinator, let id = sessionID ?? session?.id {
            if session?.id != id, let fresh = try? await coordinator.archiveStore().session(id: id) {
                session = fresh
            }
            clipCount = await coordinator.receivedChunks(sessionID: id).count
        }
        await syncActivity()
    }

    // MARK: Live Activity

    private var contentState: RecordingActivityAttributes.ContentState? {
        guard let session else { return nil }
        let phase: RecordingActivityAttributes.ContentState.Phase
        switch session.state {
        case .recording: phase = .recording
        case .paused: phase = .paused
        case .interrupted: phase = .interrupted
        default: phase = .stopped
        }
        return .init(
            phase: phase,
            startedAt: session.startedAt ?? Date(),
            clipCount: clipCount,
            lastHeardAt: lastHeardAt ?? Date()
        )
    }

    private func syncActivity() async {
        // Stay awake in the background while the watch is recording so
        // clips transcribe live; release as soon as the day stops.
        if isLive { BackgroundKeepAlive.shared.start() } else { BackgroundKeepAlive.shared.stop() }
        guard let session, let state = contentState else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
        let sessionKey = session.id.uuidString

        // A different recording day replaces any old activity.
        if let id = activityID, activitySessionID != sessionKey {
            await Self.end(id: id, content: nil, after: nil)
            activityID = nil
        }

        if isLive {
            if let id = activityID {
                await Self.update(id: id, content: content)
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                // Throws while the app is in the background; retried on foreground.
                if let started = try? Activity.request(
                    attributes: RecordingActivityAttributes(sessionID: sessionKey),
                    content: content
                ) {
                    activityID = started.id
                    activitySessionID = sessionKey
                }
            }
        } else if let id = activityID {
            await Self.end(id: id, content: content, after: Date().addingTimeInterval(5 * 60))
            activityID = nil
        }
    }

    private nonisolated static func update(
        id: String, content: ActivityContent<RecordingActivityAttributes.ContentState>
    ) async {
        guard let activity = Activity<RecordingActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content)
    }

    private nonisolated static func end(
        id: String,
        content: ActivityContent<RecordingActivityAttributes.ContentState>?,
        after date: Date?
    ) async {
        guard let activity = Activity<RecordingActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(content, dismissalPolicy: date.map { .after($0) } ?? .immediate)
    }
}

/// In-app banner shown at the top of the Recordings tab while the watch is
/// recording (or paused/interrupted).
struct LiveRecordingBanner: View {
    @ObservedObject var status: LiveRecordingStatus
    @State private var pulse = false

    var body: some View {
        if let session = status.session, status.isLive {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.25))
                        .frame(width: 34, height: 34)
                        .scaleEffect(pulse && session.state == .recording ? 1.25 : 1)
                        .animation(
                            session.state == .recording
                                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                : .default,
                            value: pulse
                        )
                    Image(systemName: symbol(session.state)).foregroundStyle(tint)
                }
                .onAppear { pulse = true }
                .onDisappear { pulse = false }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(session.state) + " on Apple Watch").font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        Text("\(status.clipCount) min saved")
                        if let heard = status.lastHeardAt {
                            Text("· updated \(heard, style: .relative) ago")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.state == .recording, let start = session.startedAt {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
            }
            .padding(12)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        }
    }

    private var tint: Color {
        switch status.session?.state {
        case .recording: return .red
        case .paused: return .orange
        default: return .yellow
        }
    }

    private func title(_ state: SessionState) -> String {
        switch state {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted"
        default: return "Stopped"
        }
    }

    private func symbol(_ state: SessionState) -> String {
        switch state {
        case .recording: return "mic.fill"
        case .paused: return "pause.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}
