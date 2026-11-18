import SwiftUI
import RecorderContracts
import PhoneIntegration

/// Phase 2 shell (I1): real pipeline status surface — engine bindings,
/// install state, queue/archive counts — so the public workflow is
/// exercisable end-to-end. U1 owns the real product UI.
struct ContentView: View {
    @ObservedObject var model: PhoneRecorderModel

    var body: some View {
        List {
            Section("Pipeline") {
                Text(model.engineLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("Speech model", value: model.speechReadiness.rawValue)
                if model.speechReadiness == .downloading {
                    ProgressView(value: model.speechProgress)
                }
                LabeledContent("Text model", value: model.textReadiness.rawValue)
                if model.textReadiness == .downloading {
                    ProgressView(value: model.textProgress)
                }
            }
            Section("Archive") {
                LabeledContent("Sessions", value: "\(model.sessionCount)")
                LabeledContent("Conversations", value: "\(model.groupCount)")
                LabeledContent("Queued jobs", value: "\(model.queuedJobs)")
                LabeledContent("Failed jobs", value: "\(model.failedJobs)")
            }
            Section {
                Button("Install models") { model.installModels() }
                Button("Process now") { model.processNow() }
            }
            if let error = model.lastError {
                Section("Error") {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle("Watch Recorder")
        .task { await model.refresh() }
    }
}
