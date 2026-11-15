import Foundation

/// One group of lines in the player's "Video Details" panel.
struct PlaybackStatsSection: Identifiable {
    let title: String
    let rows: [PlaybackStatsRow]
    var id: String { title }
}

struct PlaybackStatsRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

extension MPVPlayerController {
    /// Live numbers from mpv plus what the server said about the stream. Cheap enough to call every second.
    func readStats() -> [PlaybackStatsSection] {
        guard let core = statsCore else { return [] }
        func text(_ name: String) -> String? {
            guard let value = core.getString(name), !value.isEmpty else { return nil }
            return value
        }
        func number(_ name: String) -> Double? { text(name).flatMap(Double.init) }

        var sections: [PlaybackStatsSection] = []

        // Stream
        var stream: [PlaybackStatsRow] = []
        stream.append(row("Playback", playMethodLabel))
        if let session, session.playMethod != .directPlay {
            stream.append(row("Bitrate Limit", Bitrate.label(session.maxMbit)))
        }
        if let adaptive = session?.adaptive {
            let status = adaptive.status
            stream.append(row("Current Quality", "\(status.rungMbit.formatted(.number.precision(.fractionLength(1)))) Mbit/s"))
            if let estimate = status.estimateBps {
                stream.append(row("Measured Connection", Self.bitrate(estimate)))
            }
            stream.append(row("Quality Changes", String(status.switches)))
        }
        // ffmpeg names format families ("mov,mp4,m4a,3gp,3g2,mj2"); the server knows the actual container.
        if session?.adaptive != nil {
            stream.append(row("Container", String(localized: "HLS (adaptive)")))
        } else if let container = session?.source.container ?? text("file-format")?.split(separator: ",").first.map(String.init) {
            stream.append(row("Container", container.uppercased()))
        }
        // With automatic quality mpv only sees the playlist; size and bitrate come from the original.
        let fileSize = session?.adaptive == nil ? number("file-size") : nil
        if let fileSize, fileSize > 0 {
            stream.append(row("File Size", Self.bytes(fileSize)))
        } else if let size = session?.source.size, size > 0 {
            stream.append(row("Original File Size", Self.bytes(Double(size))))
        }
        if let fileSize, fileSize > 0, let length = number("duration"), length > 0 {
            stream.append(row("Average Bitrate", Self.bitrate(fileSize * 8 / length)))
        } else if let bitrate = session?.source.bitrate, bitrate > 0 {
            stream.append(row("Original Bitrate", Self.bitrate(Double(bitrate))))
        }
        sections.append(PlaybackStatsSection(title: String(localized: "Stream"), rows: stream))

        // Buffer
        var buffer: [PlaybackStatsRow] = []
        let target = PlaybackBuffer.seconds
        let ahead = number("demuxer-cache-duration") ?? 0
        buffer.append(row("Buffered Ahead",
                          String(localized: "\(Self.seconds(ahead)) of \(PlaybackBuffer.label(target))")))
        if let bytes = Self.forwardBytes(text("demuxer-cache-state")), bytes > 0 {
            buffer.append(row("Buffer Size", Self.bytes(bytes)))
        }
        buffer.append(row("Memory Limit", "\(PlaybackBuffer.memoryLimitMiB) MB"))
        if let speed = number("cache-speed"), speed > 0 {
            buffer.append(row("Download Speed", Self.bitrate(speed * 8)))
        }
        buffer.append(row("Waiting for Data", text("paused-for-cache") == "yes" ? String(localized: "Yes") : String(localized: "No")))
        sections.append(PlaybackStatsSection(title: String(localized: "Buffer"), rows: buffer))

        // Video
        var video: [PlaybackStatsRow] = []
        if let codec = text("video-format") ?? text("video-codec") { video.append(row("Codec", codec.uppercased())) }
        if let width = number("video-params/w"), let height = number("video-params/h") {
            video.append(row("Resolution", "\(Int(width)) × \(Int(height))"))
        }
        if let fps = number("estimated-vf-fps") ?? number("container-fps"), fps > 0 {
            video.append(row("Frame Rate", "\(fps.formatted(.number.precision(.fractionLength(0...3)))) fps"))
        }
        if let bitrate = number("video-bitrate"), bitrate > 0 { video.append(row("Current Bitrate", Self.bitrate(bitrate))) }
        let hwdec = text("hwdec-current")
        video.append(row("Hardware Decoding",
                         hwdec.flatMap { $0 == "no" ? nil : $0 } ?? String(localized: "Off")))
        let dropped = (number("frame-drop-count") ?? 0) + (number("decoder-frame-drop-count") ?? 0)
        video.append(row("Dropped Frames", String(Int(dropped))))
        if !video.isEmpty { sections.append(PlaybackStatsSection(title: String(localized: "Video"), rows: video)) }

        // Audio
        var audio: [PlaybackStatsRow] = []
        if let codec = text("audio-codec-name") { audio.append(row("Codec", codec.uppercased())) }
        if let channels = number("audio-params/channel-count") { audio.append(row("Channels", String(Int(channels)))) }
        if let rate = number("audio-params/samplerate") {
            audio.append(row("Sample Rate", "\((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"))
        }
        if let bitrate = number("audio-bitrate"), bitrate > 0 { audio.append(row("Current Bitrate", Self.bitrate(bitrate))) }
        if !audio.isEmpty { sections.append(PlaybackStatsSection(title: String(localized: "Audio"), rows: audio)) }

        return sections
    }

    private var playMethodLabel: String {
        guard let session else { return String(localized: "Local File") }
        switch session.playMethod {
        case .directPlay: return String(localized: "Direct Play")
        case .directStream: return String(localized: "Direct Stream (remuxed)")
        case .transcode: return String(localized: "Transcoding")
        }
    }

    private func row(_ label: String.LocalizationValue, _ value: String) -> PlaybackStatsRow {
        PlaybackStatsRow(label: String(localized: label), value: value)
    }

    /// `demuxer-cache-state` is a map; as a string mpv returns it as JSON with a `fw-bytes` entry.
    private static func forwardBytes(_ state: String?) -> Double? {
        guard let data = state?.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (map["fw-bytes"] as? NSNumber)?.doubleValue
    }

    private static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    /// Bits per second as "12.4 Mbit/s" or "320 kbit/s".
    private static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? "\((bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbit/s"
            : "\((bitsPerSecond / 1_000).formatted(.number.precision(.fractionLength(0)))) kbit/s"
    }

    private static func seconds(_ value: Double) -> String {
        value >= 60 ? PlaybackBuffer.label(value) : "\(value.formatted(.number.precision(.fractionLength(1)))) s"
    }
}
