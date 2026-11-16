import Foundation

/// An extra file of a download: another audio track or a subtitle, loaded after the video.
struct DownloadExtra: Codable, Equatable {
    enum Kind: String, Codable { case audio, subtitle }
    var kind: Kind
    var streamIndex: Int        // Jellyfin stream index
    var title: String
    var language: String?
    var codec: String?
    var isForced: Bool?
    var isDefault: Bool?
    var fileName: String?       // set once downloaded
    var skipped: Bool?          // the server couldn't deliver it; the download completes without it
    /// Audio tracks of transcoded downloads come as HLS segments like the video, so a dropped
    /// connection only costs the segment in flight.
    var hls: HLSProgress? = nil

    var isPending: Bool { fileName == nil && skipped != true }
}

/// What goes into an offline copy besides the video (Download sheet).
struct DownloadTrackOptions {
    /// Transcoded downloads: all other audio tracks as extra files (the video file carries one).
    var allAudioTracks = true
    /// Text subtitles as separate files (originals: only external ones; embedded ones are in the file).
    var subtitles = true

    /// The last choice from the Download sheet (also used for season downloads).
    static var stored: DownloadTrackOptions {
        let defaults = UserDefaults.standard
        return DownloadTrackOptions(
            allAudioTracks: defaults.object(forKey: SettingsKeys.downloadAllAudio) as? Bool ?? true,
            subtitles: defaults.object(forKey: SettingsKeys.downloadSubtitles) as? Bool ?? true)
    }
}

/// A transcoded video is fetched as HLS segments (fragmented MP4) that are appended to one file as
/// they arrive, so an interruption only costs the segment in flight. Jellyfin can't resume a
/// progressive transcode (it answers `Accept-Ranges: none`).
struct HLSProgress: Codable, Equatable {
    var segmentCount: Int
    /// Segments already appended (0-based index of the next one).
    var nextSegment: Int
    var hasInitSegment: Bool
    /// Size of the output file after the last append; anything beyond is cut off before continuing.
    var bytes: Int64
    /// Kept for the whole download so a restarted request can reuse the server's transcode.
    var playSessionId: String
}

struct DownloadRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, downloading, paused, completed, failed }

    let id: String              // Jellyfin item id
    var name: String
    var subtitle: String?       // series name + episode label
    var runTimeTicks: Int64?
    var mbit: Double?           // nil = original file
    var mediaSourceId: String?
    var fileName: String?
    var posterFileName: String?
    /// Whose poster was saved: "season" or "series" for episodes (instead of the episode still), "item".
    /// Episodes saved before this existed get theirs replaced once (see `DownloadManager`).
    var posterSource: String? = nil
    /// Where offline playback stopped (nil: not started or finished), when, and whether it was watched to the end.
    var resumeSeconds: Double? = nil
    var lastPlayedAt: Date? = nil
    var watched: Bool? = nil
    /// Offline progress the server doesn't know yet; sent when it's reachable.
    var playStateNeedsSync: Bool? = nil
    var state: State
    var progress: Double
    var bytesWritten: Int64
    var expectedBytes: Int64?
    var errorMessage: String?
    var createdAt: Date
    /// Failed attempts in a row; reset once a retry makes real progress.
    var retryCount: Int?
    /// While queued after an interruption: don't retry before this time.
    var retryAfter: Date?
    /// Transcoded downloads: the audio track inside the video file.
    var mainAudioIndex: Int?
    var mainAudioTitle: String?
    /// Extra audio tracks and subtitles, loaded one by one after the video.
    var extras: [DownloadExtra]?
    /// Transcoded downloads: how far the segmented video has come.
    var hls: HLSProgress?
    /// The extra audio track loading now (after the video): progress, bytes and expected size.
    var audioProgress: Double? = nil
    var audioBytesWritten: Int64? = nil
    var audioExpectedBytes: Int64? = nil

    /// The video is done and an extra audio track is loading: which one ("1 of 2") and its name.
    var audioPhase: (number: Int, total: Int, extra: DownloadExtra)? {
        guard fileName != nil, let extras, let n = nextExtraIndex, extras[n].kind == .audio else { return nil }
        let audio = extras.indices.filter { extras[$0].kind == .audio }
        return ((audio.firstIndex(of: n) ?? 0) + 1, audio.count, extras[n])
    }

    /// What the progress bars show: the video, or the audio track loading after it.
    var displayProgress: Double {
        guard let phase = audioPhase else { return progress }
        if let audioProgress { return audioProgress }
        if let hls = phase.extra.hls, hls.segmentCount > 0 { return Double(hls.nextSegment) / Double(hls.segmentCount) }
        return 0
    }

    /// The next extra file to load, once the video is done.
    var nextExtraIndex: Int? { extras?.firstIndex { $0.isPending } }
    var finishedExtras: [DownloadExtra] { (extras ?? []).filter { $0.fileName != nil } }
    /// Video done, extras still loading: "2 of 5".
    var extrasProgress: (done: Int, total: Int)? {
        guard fileName != nil, let extras, !extras.isEmpty else { return nil }
        return (extras.filter { !$0.isPending }.count, extras.count)
    }

    var qualityLabel: String {
        mbit.map { Bitrate.label($0) } ?? String(localized: "Original")
    }

    /// Queued or transferring: the manager still owns it.
    var isActive: Bool { state == .queued || state == .downloading }
}

/// What a segmented (HLS) transfer builds: the video, or an extra audio track (by its index in `extras`).
enum HLSTarget: Equatable {
    case video
    case extra(Int)
}

/// One piece of a download. Each has its own key, used as task description and file name.
enum DownloadPart: Equatable {
    /// The original file in one piece (resumable through URLSession's resume data).
    case original
    /// Transcoded: fetch the HLS playlist that lists the segments.
    case playlist
    case initSegment
    case segment(Int)
    /// An extra file in one piece (subtitles).
    case extra(Int)
    /// An extra audio track as HLS: its segment list, init segment and segments.
    case extraPlaylist(Int)
    case extraInit(Int)
    case extraSegment(Int, Int)

    func key(for id: String) -> String {
        switch self {
        case .original, .playlist: id
        case .initSegment: "\(id).init"
        case .segment(let n): "\(id).seg\(n)"
        case .extra(let n): "\(id).extra\(n)"
        case .extraPlaylist(let n): "\(id).x\(n)list"
        case .extraInit(let n): "\(id).x\(n)init"
        case .extraSegment(let n, let k): "\(id).x\(n)seg\(k)"
        }
    }

    /// The segmented transfer this part belongs to, if any.
    var hlsTarget: HLSTarget? {
        switch self {
        case .playlist, .initSegment, .segment: .video
        case .extraPlaylist(let n), .extraInit(let n), .extraSegment(let n, _): .extra(n)
        case .original, .extra: nil
        }
    }

    /// The extra file (subtitle or audio track) this part belongs to.
    var extraIndex: Int? {
        switch self {
        case .extra(let n), .extraPlaylist(let n), .extraInit(let n), .extraSegment(let n, _): n
        default: nil
        }
    }

    var isInitSegment: Bool {
        switch self {
        case .initSegment, .extraInit: true
        default: false
        }
    }

    /// Index of a media segment.
    var segmentNumber: Int? {
        switch self {
        case .segment(let k), .extraSegment(_, let k): k
        default: nil
        }
    }

    static func playlist(_ target: HLSTarget) -> DownloadPart {
        if case .extra(let n) = target { return .extraPlaylist(n) }
        return .playlist
    }

    static func initSegment(_ target: HLSTarget) -> DownloadPart {
        if case .extra(let n) = target { return .extraInit(n) }
        return .initSegment
    }

    static func segment(_ target: HLSTarget, _ k: Int) -> DownloadPart {
        if case .extra(let n) = target { return .extraSegment(n, k) }
        return .segment(k)
    }

    /// "abc.seg12" → ("abc", .segment(12)); a plain id is the original file.
    static func parse(_ key: String) -> (id: String, part: DownloadPart) {
        guard let dot = key.firstIndex(of: ".") else { return (key, .original) }
        let id = String(key[..<dot])
        let rest = key[key.index(after: dot)...]
        if rest == "init" { return (id, .initSegment) }
        if rest.hasPrefix("seg"), let n = Int(rest.dropFirst(3)) { return (id, .segment(n)) }
        if rest.hasPrefix("extra"), let n = Int(rest.dropFirst(5)) { return (id, .extra(n)) }
        if rest.hasPrefix("x"), let match = rest.wholeMatch(of: /x(\d+)(list|init|seg)(\d*)/), let n = Int(match.1) {
            switch match.2 {
            case "list": return (id, .extraPlaylist(n))
            case "init": return (id, .extraInit(n))
            default: if let k = Int(match.3) { return (id, .extraSegment(n, k)) }
            }
        }
        return (key, .original)
    }
}

/// The segment list of a transcoded download, stored next to it (`.<id>.hls.json`). URLs are kept
/// without the access token, which is added at request time.
struct HLSSegmentList: Codable {
    var initURL: String
    var segmentURLs: [String]

    /// Parses Jellyfin's `main.m3u8` (VOD playlist with `#EXT-X-MAP` for fMP4).
    static func parse(_ text: String, relativeTo base: URL) -> HLSSegmentList? {
        var initURL: String?
        var segments: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:") {
                if let start = line.range(of: "URI=\"")?.upperBound,
                   let end = line[start...].firstIndex(of: "\"") {
                    initURL = resolve(String(line[start..<end]), base)
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = resolve(line, base) {
                segments.append(url)
            }
        }
        guard let initURL, !segments.isEmpty else { return nil }
        return HLSSegmentList(initURL: initURL, segmentURLs: segments)
    }

    private static func resolve(_ reference: String, _ base: URL) -> String? {
        guard let url = URL(string: reference, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = components.queryItems?.filter { !["api_key", "apikey"].contains($0.name.lowercased()) }
        return components.url?.absoluteString
    }

    static func url(_ stored: String, token: String?) -> URL? {
        guard var components = URLComponents(string: stored) else { return nil }
        var items = components.queryItems ?? []
        if let token { items.append(URLQueryItem(name: "api_key", value: token)) }
        components.queryItems = items
        return components.url
    }
}
