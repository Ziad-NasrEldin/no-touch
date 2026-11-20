import SwiftUI
import WidgetKit
import ActivityKit

@main
struct RecorderWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(state.phase.title).font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: state.phase.symbol).foregroundStyle(state.phase.tint)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(state.clipCount) min saved")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    ElapsedText(state: state)
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Apple Watch · last update \(state.lastHeardAt, style: .relative) ago")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: state.phase.symbol)
                    .foregroundStyle(state.phase.tint)
            } compactTrailing: {
                ElapsedText(state: state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 56)
                    .foregroundStyle(state.phase.tint)
            } minimal: {
                Image(systemName: state.phase.symbol)
                    .foregroundStyle(state.phase.tint)
            }
            .keylineTint(state.phase.tint)
        }
    }
}

private struct LockScreenView: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(state.phase.tint.opacity(0.2)).frame(width: 44, height: 44)
                Image(systemName: state.phase.symbol)
                    .font(.title3)
                    .foregroundStyle(state.phase.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase.title + " on Apple Watch")
                    .font(.headline).foregroundStyle(.white)
                Text("\(state.clipCount) min saved · updated \(state.lastHeardAt, style: .relative) ago")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            ElapsedText(state: state)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding()
    }
}

private struct ElapsedText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text(Self.format(state.lastHeardAt.timeIntervalSince(state.startedAt)))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

extension RecordingActivityAttributes.ContentState.Phase {
    var title: String {
        switch self {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted"
        case .stopped: return "Stopped"
        }
    }

    var symbol: String {
        switch self {
        case .recording: return "mic.fill"
        case .paused: return "pause.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recording: return .red
        case .paused: return .orange
        case .interrupted: return .yellow
        case .stopped: return .gray
        }
    }
}
