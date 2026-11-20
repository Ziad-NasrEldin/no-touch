import RecorderContracts
import SwiftUI
import WatchCapture

/// Exercise shell for the real capture path: start/pause/resume/stop drive
/// `WatchCaptureService`, and the status reads come straight from
/// `stateUpdates()` plus real outbox counts — no mocks.
struct ContentView: View {
    @EnvironmentObject private var model: RecorderModel
    @Environment(\.scenePhase) private var scenePhase

    private var state: SessionState { model.session?.state ?? .idle }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("No Touch")
                    .font(.headline)

                Text(state.rawValue)
                    .font(.title3)
                    .foregroundStyle(stateColor)

                if let failure = model.session?.failureReason {
                    Text(failure.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if let confirmed = model.session?.lastConfirmedCaptureAt {
                    Text("captured \(confirmed.formatted(.relative(presentation: .numeric)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                let gaps = model.session?.interruptionIntervals.count ?? 0
                Text("chunks \(model.finalizedCount) · queued \(model.awaitingAckCount)"
                    + (gaps > 0 ? " · gaps \(gaps)" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }

                controls
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .idle, .stopped:
            Button("Start day", action: model.start)
                .tint(.green)
                .disabled(model.busy)
        case .recording:
            HStack {
                Button("Pause", action: model.pause)
                Button("Stop", role: .destructive, action: model.stop)
            }
            .disabled(model.busy)
        case .paused, .interrupted:
            VStack(spacing: 4) {
                Button("Resume", action: model.resume)
                    .tint(.green)
                Button("Stop", role: .destructive, action: model.stop)
            }
            .disabled(model.busy)
        }
    }

    private var stateColor: Color {
        switch state {
        case .recording: return .green
        case .interrupted: return .orange
        case .paused: return .yellow
        case .idle, .stopped: return .secondary
        }
    }
}
