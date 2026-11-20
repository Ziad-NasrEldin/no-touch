import SwiftUI
import UIKit
import RecorderContracts
import PhoneIntegration

/// iPhone-local day recording controls mirroring the Apple Watch capture UI:
/// Start day / Pause / Resume / Stop, truthful session state, chunk counts,
/// microphone permission state, failure reasons, and interruption gaps.
struct RecordView: View {
    @ObservedObject var model: PhoneRecorderModel
    @ObservedObject var live: LiveRecordingStatus
    @Environment(\.openURL) private var openURL

    private var session: RecordingSession? { model.phoneSession }
    private var state: SessionState { session?.state ?? .idle }
    private var gaps: [InterruptionInterval] { session?.interruptionIntervals ?? [] }
    private var isMicrophoneDenied: Bool {
        model.microphonePermission == .denied || session?.failureReason == .microphoneDenied
    }

    var body: some View {
        List {
            if isMicrophoneDenied {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Microphone access denied", systemImage: "mic.slash.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("No Touch needs microphone permission to record conversations on this iPhone. Enable Microphone access in Settings, then return here to start your day.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            Label("Open Settings", systemImage: "gear")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }

            if live.isLive && live.source == .watch && state != .recording {
                Section {
                    Label("An Apple Watch recording session is currently active.", systemImage: "applewatch.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                statusHeader
                controls
            } footer: {
                Text("Records in 1-minute audio clips on this iPhone and feeds them into the same local transcription and conversation archive as Apple Watch recordings. Capture continues with the screen locked where iOS permits.")
            }

            if let failure = session?.failureReason {
                Section("Failure reason") {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(Self.failureTitle(failure), systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(Self.failureDetail(failure))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Code: \(failure.rawValue)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }

            if let error = model.phoneCaptureError {
                Section("Error") {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Session") {
                LabeledContent("State", value: state.rawValue)
                LabeledContent("Chunks recorded", value: "\(model.phoneFinalizedCount)")
                LabeledContent("Archived in pipeline", value: "\(model.phoneArchivedCount)")
                if model.phonePendingIngestCount > 0 {
                    LabeledContent("Pending archive", value: "\(model.phonePendingIngestCount)")
                }
                LabeledContent("Interruption gaps", value: "\(gaps.count)")
                if let confirmed = session?.lastConfirmedCaptureAt {
                    LabeledContent("Last confirmed") {
                        Text(confirmed, style: .relative) + Text(" ago")
                    }
                }
                if let started = session?.startedAt {
                    LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened))
                }
                if let stopped = session?.stoppedAt {
                    LabeledContent("Stopped", value: stopped.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if !gaps.isEmpty {
                Section {
                    ForEach(Array(gaps.enumerated().reversed()), id: \.offset) { _, gap in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Self.failureTitle(gap.reason))
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if let endedAt = gap.endedAt {
                                    Text(RecordingsView.duration(endedAt.timeIntervalSince(gap.beganAt)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("Ongoing")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(Self.gapWindow(gap))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Interruption gaps")
                } footer: {
                    Text("Gaps mark intervals without confirmed audio, not silence.")
                }
            }
        }
        .navigationTitle("Record")
        .refreshable {
            await model.refreshPhoneCaptureState()
        }
        .task {
            await model.refreshPhoneCaptureState()
        }
    }

    // MARK: - Subviews

    private var statusHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.2))
                    .frame(width: 48, height: 48)
                Image(systemName: stateSymbol)
                    .font(.title3)
                    .foregroundStyle(stateColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(stateTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(stateColor)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state == .recording, let start = session?.startedAt {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 96, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .idle, .stopped:
            Button {
                model.startPhoneRecording()
            } label: {
                HStack {
                    if model.phoneCaptureBusy {
                        ProgressView().padding(.trailing, 4)
                    }
                    Label("Start day", systemImage: "record.circle")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(model.phoneCaptureBusy)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

        case .recording:
            HStack(spacing: 12) {
                Button {
                    model.pausePhoneRecording()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    model.stopPhoneRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .disabled(model.phoneCaptureBusy)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

        case .paused, .interrupted:
            HStack(spacing: 12) {
                Button {
                    model.resumePhoneRecording()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(role: .destructive) {
                    model.stopPhoneRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .disabled(model.phoneCaptureBusy)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Formatting

    private var stateTitle: String {
        switch state {
        case .idle: return "Ready to record"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted"
        case .stopped: return "Stopped"
        }
    }

    private var subtitleText: String {
        let gapSuffix = gaps.isEmpty ? "" : " · \(gaps.count) \(gaps.count == 1 ? "gap" : "gaps")"
        switch state {
        case .idle:
            return "iPhone microphone inactive"
        case .recording:
            return "\(model.phoneFinalizedCount) \(model.phoneFinalizedCount == 1 ? "chunk" : "chunks") saved\(gapSuffix)"
        case .paused:
            return "Microphone paused · \(model.phoneFinalizedCount) saved\(gapSuffix)"
        case .interrupted:
            return "Capture interrupted · tap Resume to continue"
        case .stopped:
            return "Session ended · \(model.phoneFinalizedCount) \(model.phoneFinalizedCount == 1 ? "chunk" : "chunks") saved\(gapSuffix)"
        }
    }

    private var stateSymbol: String {
        switch state {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .paused: return "pause.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.fill"
        }
    }

    private var stateColor: Color {
        switch state {
        case .recording: return .red
        case .interrupted: return .orange
        case .paused: return .yellow
        case .idle, .stopped: return .secondary
        }
    }

    private static func failureTitle(_ reason: FailureReason) -> String {
        switch reason {
        case .microphoneDenied: return "Microphone permission denied"
        case .lowStorage: return "Low device storage"
        case .lowBattery: return "Low battery"
        case .audioSessionInterrupted: return "Audio session interrupted"
        case .unrecoverableTermination: return "App terminated during capture"
        case .unknown: return "Capture interrupted"
        }
    }

    private static func failureDetail(_ reason: FailureReason) -> String {
        switch reason {
        case .microphoneDenied:
            return "Allow Microphone access in iPhone Settings, then tap Resume or Start day."
        case .lowStorage:
            return "Free up storage space on this iPhone before resuming recording."
        case .lowBattery:
            return "Charge this iPhone before resuming recording."
        case .audioSessionInterrupted:
            return "Another app, call, or system alert took control of audio."
        case .unrecoverableTermination:
            return "The app stopped unexpectedly while recording. Completed chunks were preserved; tap Resume to continue this day."
        case .unknown:
            return "Recording stopped unexpectedly. Tap Resume to restore capture."
        }
    }

    private static func gapWindow(_ gap: InterruptionInterval) -> String {
        let start = gap.beganAt.formatted(date: .omitted, time: .standard)
        if let end = gap.endedAt {
            return "\(start) – \(end.formatted(date: .omitted, time: .standard))"
        }
        return "Started \(start) – ongoing"
    }
}
