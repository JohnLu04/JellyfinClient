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
    enum State: String, Codable { case queued, downloading, completed, failed }

    let id: String              // Jellyfin item id
    var name: String
    var subtitle: String?       // series name + episode label
    var runTimeTicks: Int64?
    var mbit: Double?           // nil = original file
    var mediaSourceId: String?
    var fileName: String?
    var posterFileName: String?
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

/// One piece of a download. Each has its own key, used as task description and file name.
enum DownloadPart: Equatable {
    /// The original file in one piece (resumable through URLSession's resume data).
    case original
    /// Transcoded: fetch the HLS playlist that lists the segments.
    case playlist
    case initSegment
    case segment(Int)
    case extra(Int)

    func key(for id: String) -> String {
        switch self {
        case .original, .playlist: id
        case .initSegment: "\(id).init"
        case .segment(let n): "\(id).seg\(n)"
        case .extra(let n): "\(id).extra\(n)"
        }
    }

    /// "abc.seg12" → ("abc", .segment(12)); a plain id is the original file.
    static func parse(_ key: String) -> (id: String, part: DownloadPart) {
        guard let dot = key.firstIndex(of: ".") else { return (key, .original) }
        let id = String(key[..<dot])
        let rest = key[key.index(after: dot)...]
        if rest == "init" { return (id, .initSegment) }
        if rest.hasPrefix("seg"), let n = Int(rest.dropFirst(3)) { return (id, .segment(n)) }
        if rest.hasPrefix("extra"), let n = Int(rest.dropFirst(5)) { return (id, .extra(n)) }
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
