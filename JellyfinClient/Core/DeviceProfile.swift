import Foundation

/// Tells the server what the iPhone can play natively (AVPlayer).
/// Anything else is remuxed or transcoded to HLS (fMP4 segments, H.264/HEVC + AAC/AC3).
enum DeviceProfile {
    static func make(maxBitrate: Int) -> [String: Any] {
        [
            "Name": "JellyfinClient iOS",
            "MaxStreamingBitrate": maxBitrate,
            "MaxStaticBitrate": maxBitrate,
            "MusicStreamingTranscodingBitrate": 320_000,
            "DirectPlayProfiles": [
                [
                    "Container": "mp4,m4v,mov",
                    "Type": "Video",
                    "VideoCodec": "h264,hevc",
                    "AudioCodec": "aac,mp3,ac3,eac3,alac,flac",
                ],
            ],
            "TranscodingProfiles": [
                [
                    "Container": "mp4",
                    "Type": "Video",
                    "VideoCodec": "h264,hevc",
                    "AudioCodec": "aac,ac3,eac3",
                    "Protocol": "hls",
                    "Context": "Streaming",
                    "MaxAudioChannels": "6",
                    "MinSegments": 2,
                    "BreakOnNonKeyFrames": true,
                ],
            ],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            "SubtitleProfiles": [
                ["Format": "vtt", "Method": "Hls"],
                ["Format": "srt", "Method": "Encode"],
                ["Format": "ass", "Method": "Encode"],
                ["Format": "ssa", "Method": "Encode"],
                ["Format": "pgssub", "Method": "Encode"],
                ["Format": "dvdsub", "Method": "Encode"],
            ],
        ]
    }
}
