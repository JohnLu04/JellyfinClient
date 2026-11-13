import Foundation

// Jellyfin returns PascalCase JSON. `JSONCoding` maps it to camelCase Swift properties,
// so the models below can use normal Swift naming.

struct PublicSystemInfo: Decodable {
    let serverName: String?
    let version: String?
    let id: String?
}

struct AuthenticationResult: Decodable {
    let user: UserDto
    let accessToken: String
}

struct UserDto: Decodable {
    let id: String
    let name: String?
    let policy: UserPolicy?
}

struct UserPolicy: Decodable {
    let enableContentDownloading: Bool?
    let enableVideoPlaybackTranscoding: Bool?
}

struct ItemsResult: Decodable {
    let items: [BaseItem]
    let totalRecordCount: Int?
}

struct Person: Decodable, Hashable {
    let name: String?
    let role: String?
    let type: String?
}

struct RemoteTrailer: Decodable, Hashable {
    let url: String?
    let name: String?
}

struct UserItemData: Decodable {
    let playbackPositionTicks: Int64?
    let playedPercentage: Double?
    let played: Bool?
    let isFavorite: Bool?
}

struct MediaSourceInfo: Decodable {
    let id: String?
    let name: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let runTimeTicks: Int64?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let transcodingUrl: String?
    let mediaStreams: [MediaStream]?
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?

    var audioStreams: [MediaStream] { (mediaStreams ?? []).filter { $0.type == "Audio" } }
    var subtitleStreams: [MediaStream] { (mediaStreams ?? []).filter { $0.type == "Subtitle" } }
}

/// One video, audio or subtitle stream of a media source. `index` is Jellyfin's stream index.
struct MediaStream: Decodable, Identifiable, Hashable {
    let index: Int
    let type: String?
    let codec: String?
    let language: String?
    let title: String?
    let displayTitle: String?
    let isDefault: Bool?
    let isForced: Bool?
    let isExternal: Bool?
    let isTextSubtitleStream: Bool?
    let deliveryMethod: String?
    let deliveryUrl: String?
    let channels: Int?
    let width: Int?
    let height: Int?

    var id: Int { index }

    var label: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        let parts = [title, language?.uppercased(), codec?.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Track \(index)" : parts.joined(separator: " · ")
    }

    /// Text subtitles can be delivered as separate files; image subtitles (PGS, VobSub) can't.
    var isTextSubtitle: Bool {
        if let isTextSubtitleStream { return isTextSubtitleStream }
        let textCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "sub", "smi", "ttml", "text"]
        return textCodecs.contains((codec ?? "").lowercased())
    }
}

/// The audio/subtitle choice for a playback. `subtitleIndex == nil` means subtitles off.
struct TrackSelection: Equatable {
    var audioIndex: Int?
    var subtitleIndex: Int?

    static func defaults(for source: MediaSourceInfo?) -> TrackSelection {
        let audio = source?.defaultAudioStreamIndex ?? source?.audioStreams.first(where: { $0.isDefault == true })?.index
            ?? source?.audioStreams.first?.index
        let subtitle = source?.defaultSubtitleStreamIndex.flatMap { $0 >= 0 ? $0 : nil }
        return TrackSelection(audioIndex: audio, subtitleIndex: subtitle)
    }
}

extension Array where Element == MediaStream {
    /// Position of a stream among the streams embedded in the file (external ones excluded),
    /// which is how players number their tracks.
    func embeddedOrdinal(of index: Int) -> Int? {
        filter { $0.isExternal != true }.sorted { $0.index < $1.index }.firstIndex { $0.index == index }
    }
}

struct PlaybackInfoResponse: Decodable {
    let mediaSources: [MediaSourceInfo]?
    let playSessionId: String?
    let errorCode: String?
}

struct BaseItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String?
    let collectionType: String?
    let isFolder: Bool?
    let overview: String?
    let productionYear: Int?
    let runTimeTicks: Int64?
    let officialRating: String?
    let communityRating: Double?
    let seriesName: String?
    let seriesId: String?
    let seasonId: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let parentThumbItemId: String?
    let parentThumbImageTag: String?
    let seriesPrimaryImageTag: String?
    let parentLogoItemId: String?
    let parentLogoImageTag: String?
    let genres: [String]?
    let people: [Person]?
    let providerIds: [String: String]?
    let remoteTrailers: [RemoteTrailer]?
    let localTrailerCount: Int?
    let childCount: Int?
    let premiereDate: String?
    let userData: UserItemData?
    let mediaSources: [MediaSourceInfo]?

    static func == (lhs: BaseItem, rhs: BaseItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension BaseItem {
    enum Kind { case playable, series, folder, unsupported }

    var kind: Kind {
        switch type {
        case "Movie", "Episode", "Video", "MusicVideo": return .playable
        case "Series": return .series
        default: return isFolder == true ? .folder : .unsupported
        }
    }

    /// Image tag lookup that ignores key casing.
    func imageTag(_ imageType: String) -> String? {
        imageTags?.first { $0.key.caseInsensitiveCompare(imageType) == .orderedSame }?.value
    }

    var resumeTicks: Int64 { userData?.playbackPositionTicks ?? 0 }

    var progressFraction: Double? {
        guard resumeTicks > 0, let total = runTimeTicks, total > 0 else { return nil }
        return min(1, Double(resumeTicks) / Double(total))
    }

    var runtimeText: String? { runTimeTicks.map { Ticks.durationText($0) } }

    /// "S1 · E3" style label for episodes.
    var episodeLabel: String? {
        guard type == "Episode" else { return nil }
        switch (parentIndexNumber, indexNumber) {
        case let (s?, e?): return "S\(s) · E\(e)"
        case let (nil, e?): return "E\(e)"
        default: return nil
        }
    }

    /// Libraries this client knows how to browse (video only).
    var isSupportedLibrary: Bool {
        switch collectionType {
        case nil, "movies", "tvshows", "homevideos", "boxsets", "mixed", "musicvideos", "folders": return true
        default: return false
        }
    }

    var primaryMediaSource: MediaSourceInfo? { mediaSources?.first }

    var isFavorite: Bool { userData?.isFavorite == true }

    /// Provider id lookup that ignores key casing ("Imdb", "Tmdb", …).
    func providerID(_ name: String) -> String? {
        providerIds?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Link for the share button: the IMDb page, falling back to TMDb.
    var shareURL: URL? {
        if let imdb = providerID("Imdb"), !imdb.isEmpty {
            return URL(string: "https://www.imdb.com/title/\(imdb)/")
        }
        if let tmdb = providerID("Tmdb"), !tmdb.isEmpty {
            return URL(string: "https://www.themoviedb.org/\(type == "Series" ? "tv" : "movie")/\(tmdb)")
        }
        return nil
    }

    var castNames: [String] {
        (people ?? []).filter { $0.type == "Actor" }.compactMap(\.name)
    }

    /// Directors, or writers/creators when there's no director (common for series).
    var creatorNames: [String] {
        let all = people ?? []
        let directors = all.filter { $0.type == "Director" }.compactMap(\.name)
        if !directors.isEmpty { return directors }
        return all.filter { $0.type == "Writer" || $0.type == "Creator" }.compactMap(\.name)
    }

    /// "4K" / "HD" based on the main video stream.
    var videoQualityBadge: String? {
        guard let video = primaryMediaSource?.mediaStreams?.first(where: { $0.type == "Video" }),
              let width = video.width else { return nil }
        if width >= 3800 { return "4K" }
        if width >= 1260 { return "HD" }
        return nil
    }

    var hasSubtitles: Bool { !(primaryMediaSource?.subtitleStreams.isEmpty ?? true) }

    /// "S3 · E2"-style label for the play button of a series.
    var shortEpisodeLabel: String? {
        guard let season = parentIndexNumber, let episode = indexNumber else { return episodeLabel }
        return "S\(season) · E\(episode)"
    }
}

enum Ticks {
    static let perSecond: Double = 10_000_000

    static func seconds(_ ticks: Int64) -> Double { Double(ticks) / perSecond }
    static func ticks(_ seconds: Double) -> Int64 { seconds.isFinite ? Int64(seconds * perSecond) : 0 }

    static func durationText(_ ticks: Int64) -> String {
        let minutes = Int(seconds(ticks) / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(minutes, 1)) min"
    }

    static func clockText(_ ticks: Int64) -> String {
        let total = Int(seconds(ticks))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension Notification.Name {
    /// Posted when the player closes, so screens can refresh resume positions.
    static let playbackDidStop = Notification.Name("JellyfinClient.playbackDidStop")
    /// Posted right before a player opens, so inline trailers can stop.
    static let playbackWillStart = Notification.Name("JellyfinClient.playbackWillStart")
}
