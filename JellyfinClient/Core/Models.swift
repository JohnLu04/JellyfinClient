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
}
