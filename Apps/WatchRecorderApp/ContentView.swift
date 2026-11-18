import SwiftUI
import RecorderContracts
import WatchCapture

/// Phase 0 placeholder shell. Binds to the real capture contract through the
/// placeholder service; C1/U1 replace controls and state display with the
/// shipped capture UI.
struct ContentView: View {
    private let capture = PlaceholderCaptureService()

    @State private var state: SessionState = .idle

    var body: some View {
        VStack(spacing: 8) {
            Text("Recorder")
                .font(.headline)
            Text(state.rawValue)
                .foregroundStyle(.secondary)
        }
        .task {
            state = await capture.currentSession()?.state ?? .idle
        }
    }
}
