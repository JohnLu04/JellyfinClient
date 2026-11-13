import Foundation

/// Tells the server what the selected player can play directly.
/// Anything else is remuxed or transcoded to HLS.
enum DeviceProfile {
    static func make(maxBitrate: Int, player: PlayerKind) -> [String: Any] {
        var profile: [String: Any] = [
            "Name": "JellyfinClient iOS (\(player.rawValue))",
            "MaxStreamingBitrate": maxBitrate,
            "MaxStaticBitrate": maxBitrate,
            "MusicStreamingTranscodingBitrate": 320_000,
            "ContainerProfiles": [],
            "CodecProfiles": [],
        ]
        switch player {
        case .native:
            profile["DirectPlayProfiles"] = [
                ["Container": "mp4,m4v,mov", "Type": "Video",
                 "VideoCodec": "h264,hevc", "AudioCodec": "aac,mp3,ac3,eac3,alac,flac"],
            ]
            profile["TranscodingProfiles"] = [
                ["Container": "mp4", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3",
                 "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "6",
                 "MinSegments": 2, "BreakOnNonKeyFrames": true],
            ]
            profile["SubtitleProfiles"] = [
                ["Format": "vtt", "Method": "Hls"],
                ["Format": "mov_text", "Method": "Embed"],
            ] + imageAndTextFormats.map { ["Format": $0, "Method": "Encode"] }

        case .mpv:
            // mpv (FFmpeg) decodes practically everything: empty codec lists mean "any codec".
            profile["DirectPlayProfiles"] = [
                ["Container": "mkv,webm,mp4,m4v,mov,avi,ts,m2ts,mts,mpegts,flv,wmv,asf,mpg,mpeg,vob,ogv,ogg,3gp",
                 "Type": "Video"],
            ]
            profile["TranscodingProfiles"] = [
                ["Container": "ts", "Type": "Video", "VideoCodec": "h264,hevc",
                 "AudioCodec": "aac,ac3,eac3,mp3,opus,flac",
                 "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "8",
                 "MinSegments": 1, "BreakOnNonKeyFrames": true],
            ]
            // Embedded subtitles stay in the file; text subtitles can also be loaded as separate files.
            profile["SubtitleProfiles"] =
                imageAndTextFormats.map { ["Format": $0, "Method": "Embed"] }
                + textFormats.map { ["Format": $0, "Method": "External"] }
                + imageFormats.map { ["Format": $0, "Method": "Encode"] }
        }
        return profile
    }

    private static let textFormats = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "sub", "smi", "ttml"]
    private static let imageFormats = ["pgssub", "pgs", "dvdsub", "dvbsub", "vobsub"]
    private static var imageAndTextFormats: [String] { textFormats + imageFormats + ["mov_text"] }
}
