import Foundation

/// Which video player is used. Chosen in Settings, applies to the next playback.
enum PlayerKind: String, CaseIterable, Identifiable {
    case mpv
    case native

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mpv: return "mpv"
        case .native: return String(localized: "Apple Player (AVPlayer)")
        }
    }

    var summary: String {
        switch self {
        case .mpv:
            return String(localized: "Plays almost every format directly (MKV, HEVC, AV1, DTS, PGS subtitles …), so the server transcodes less. Switch between all audio tracks and subtitles right in the player.")
        case .native:
            return String(localized: "Apple's system player with Picture in Picture and AirPlay. Formats the iPhone can't play natively are converted by the server.")
        }
    }

    static let defaultKind: PlayerKind = .mpv

    static var current: PlayerKind {
        UserDefaults.standard.string(forKey: SettingsKeys.videoPlayer).flatMap(PlayerKind.init(rawValue:)) ?? defaultKind
    }
}
