import ActivityKit
import Foundation

/// The download progress on the Lock Screen and in the Dynamic Island (a Live Activity). Shared by the
/// app, which starts and updates it, and the widget extension, which draws it.
///
/// One activity covers the whole download queue: iOS only lets an app start a Live Activity while it is
/// in the foreground, so it is started when a download begins and then switches from title to title.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case downloading, waiting, completed, failed
        }

        var itemId: String
        var title: String
        var subtitle: String?
        /// Already localized by the app ("Wird heruntergeladen", "Fertig", …).
        var status: String
        var phase: Phase
        /// 0...1
        var progress: Double
        var bytesWritten: Int64
        var totalBytes: Int64?
        var bytesPerSecond: Double?
        /// Titles waiting after this one.
        var queued: Int
        /// A small JPEG of the poster. A Live Activity's data is limited to 4 KB, so it is tiny.
        var poster: Data?
    }
}
