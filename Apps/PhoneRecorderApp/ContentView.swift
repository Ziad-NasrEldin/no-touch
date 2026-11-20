import SwiftUI
import RecorderContracts
import PhoneIntegration

/// Pipeline status, model installation, and manual processing controls.
struct ContentView: View {
    @ObservedObject var model: PhoneRecorderModel

    var body: some View {
        List {
            Section {
                Text("1. Your Apple Watch or iPhone records in short clips and saves them to the local archive.\n2. The speech model turns each clip into text.\n3. The text model groups text into conversations and adds a title, summary and category.\n\nInstall both models once over Wi-Fi (about 1.7 GB), then tap Process now. Afterwards processing runs automatically.")
                    .font(.footnote)
            } header: {
                Text("How it works")
            }

            Section("Pipeline") {
                Text(model.engineLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ModelStatusRow(
                    title: "Speech model",
                    state: model.speechReadiness,
                    progress: model.speechProgress,
                    downloadedBytes: model.speechDownloadedBytes,
                    expectedBytes: model.speechExpectedBytes,
                    failureReason: model.speechFailureReason
                )

                ModelStatusRow(
                    title: "Text model",
                    state: model.textReadiness,
                    progress: model.textProgress,
                    downloadedBytes: model.textDownloadedBytes,
                    expectedBytes: model.textExpectedBytes,
                    failureReason: model.textFailureReason
                )
            }

            Section("Archive") {
                LabeledContent("Sessions", value: "\(model.sessionCount)")
                LabeledContent("Audio clips", value: "\(model.chunkCount)")
                LabeledContent("Conversations", value: "\(model.groupCount)")
                LabeledContent("Queued jobs", value: "\(model.queuedJobs)")
                LabeledContent("Failed jobs", value: "\(model.failedJobs)")
            }

            Section("Actions") {
                Button {
                    model.installModels()
                } label: {
                    HStack {
                        if model.isInstalling {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text(model.installStage ?? "Installing models…")
                        } else if model.allModelsReady {
                            Label("Models installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if model.speechReadiness == .failed || model.textReadiness == .failed {
                            Label("Retry model install", systemImage: "arrow.clockwise.circle")
                        } else {
                            Label("Install models", systemImage: "arrow.down.circle")
                        }
                        Spacer()
                    }
                }
                .disabled(model.isInstalling)

                if model.isInstalling {
                    Button(role: .destructive) {
                        model.cancelInstall()
                    } label: {
                        Label("Cancel install", systemImage: "xmark.circle")
                    }
                }

                Button {
                    model.processNow()
                } label: {
                    HStack {
                        if model.isProcessing {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text("Processing…")
                        } else {
                            Label("Process now", systemImage: "sparkles")
                        }
                        Spacer()
                    }
                }
                .disabled(model.isProcessing || model.isInstalling)

                if let status = model.statusMessage, !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pipeline-status-message")
                }
            }

            if model.lastError != nil || model.recentJobError != nil {
                Section("Errors") {
                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                    if let jobError = model.recentJobError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latest failed job")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                            Text(jobError)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("No Touch")
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }
}

private struct ModelStatusRow: View {
    let title: String
    let state: ModelReadinessState
    let progress: Double
    let downloadedBytes: Int64
    let expectedBytes: Int64?
    let failureReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    if state == .verifying || (state == .downloading && progress <= 0) {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }
            }
            if state == .downloading && progress > 0 {
                ProgressView(value: min(max(progress, 0), 1))
                if let byteSummary {
                    Text(byteSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if state == .failed, let failureReason, !failureReason.isEmpty {
                Text(failureReason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusText: String {
        switch state {
        case .downloading where progress > 0:
            return "Downloading (\(Int((progress * 100).rounded()))%)"
        default:
            return PhoneRecorderModel.readinessLabel(state)
        }
    }

    private var statusColor: Color {
        switch state {
        case .ready: return .green
        case .failed: return .red
        case .downloading, .verifying: return .accentColor
        case .notInstalled: return .secondary
        }
    }

    @MainActor
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var byteSummary: String? {
        guard downloadedBytes > 0 else { return nil }
        let done = Self.byteFormatter.string(fromByteCount: downloadedBytes)
        if let expectedBytes, expectedBytes > 0 {
            let total = Self.byteFormatter.string(fromByteCount: expectedBytes)
            return "\(done) / \(total)"
        }
        return done
    }
}
