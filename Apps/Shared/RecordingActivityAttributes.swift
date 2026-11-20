import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity model shared by the iPhone app and the widget extension.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording, paused, interrupted, stopped
        }

        enum Source: String, Codable, Hashable {
            case watch, phone

            var deviceName: String {
                switch self {
                case .watch: return "Apple Watch"
                case .phone: return "iPhone"
                }
            }
        }

        var phase: Phase
        /// When the recording day started (drives the timer).
        var startedAt: Date
        /// Clips archived on the iPhone so far today.
        var clipCount: Int
        /// When the live status last updated.
        var lastHeardAt: Date
        /// Which device is capturing this session.
        var source: Source = .watch
    }

    var sessionID: String
}
#endif
