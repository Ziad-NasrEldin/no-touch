import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity model shared by the iPhone app and the widget extension.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording, paused, interrupted, stopped
        }

        var phase: Phase
        /// When the recording day started on the watch (drives the timer).
        var startedAt: Date
        /// Clips received by the iPhone so far today.
        var clipCount: Int
        /// When the iPhone last heard from the watch.
        var lastHeardAt: Date
    }

    var sessionID: String
}
#endif
