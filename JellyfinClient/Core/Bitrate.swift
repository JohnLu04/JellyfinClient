import Foundation

/// Bitrates are stored in Mbit/s and always snapped to 0.5 Mbit/s steps.
/// For streaming, 0 means "Original" (no limit).
enum Bitrate {
    static let step = 0.5
    static let range: ClosedRange<Double> = 0.5...120
    /// Used when no limit is set; high enough that the server never transcodes for bitrate reasons.
    static let unlimitedBps = 200_000_000

    static func snap(_ mbit: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (mbit / step).rounded() * step))
    }

    static func bps(forMbit mbit: Double) -> Int {
        mbit > 0 ? Int(mbit * 1_000_000) : unlimitedBps
    }

    static func label(_ mbit: Double) -> String {
        guard mbit > 0 else { return String(localized: "Original") }
        return mbit.formatted(.number.precision(.fractionLength(1))) + " Mbit/s"
    }

    /// Resolution cap for a given bitrate so low bitrates don't produce blocky 4K output.
    static func maxWidth(forMbit mbit: Double) -> Int? {
        switch mbit {
        case ..<1.0: return 640
        case ..<2.5: return 854
        case ..<6.0: return 1280
        case ..<15.0: return 1920
        default: return nil
        }
    }

    /// Rough size of a transcoded file.
    static func estimatedBytes(mbit: Double, runTimeTicks: Int64?) -> Int64? {
        guard mbit > 0, let ticks = runTimeTicks, ticks > 0 else { return nil }
        return Int64(mbit * 1_000_000 / 8 * Ticks.seconds(ticks))
    }
}

enum SettingsKeys {
    static let streamingMbit = "settings.streamingMbit"   // 0 = original
    static let downloadMbit = "settings.downloadMbit"
    static let lastServerAddress = "settings.lastServerAddress"
    static let videoPlayer = "settings.videoPlayer"         // PlayerKind raw value
}
