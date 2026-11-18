import SwiftUI
import RecorderContracts
import PhoneAI
import PhoneStorage
import PhoneIntegration

/// Phase 0 placeholder shell. Exercises the receive → archive → analysis seam
/// with placeholder implementations; U1 replaces this with the real timeline.
struct ContentView: View {
    private let coordinator = SessionCoordinator(
        receiver: PlaceholderReceiveService(),
        archive: PlaceholderArchiveStore(),
        transcriber: PlaceholderSpeechTranscriptionAdapter(),
        intelligence: PlaceholderTextIntelligenceAdapter()
    )

    @State private var readiness: ModelReadinessState = .notInstalled

    var body: some View {
        VStack(spacing: 12) {
            Text("Watch Recorder")
                .font(.headline)
            Text("Model readiness: \(readiness.rawValue)")
                .foregroundStyle(.secondary)
        }
        .task {
            readiness = await coordinator.transcriptionReadiness()
        }
    }
}
