import SwiftUI

// Seerr (Overseerr / Jellyseerr) API client – the same integration as in the Servarr app.


// MARK: - API types (Seerr / Overseerr / Jellyseerr, API v1)

struct SeerrStatus: Decodable, Sendable {
    let version: String
}

struct SeerrRequestPage: Decodable, Sendable {
    let results: [SeerrRequest]
}

struct SeerrRequest: Decodable, Sendable {
    let id: Int
    let status: Int
    let type: String?
    let createdAt: Date?
    let is4k: Bool?
    let media: Media
    let requestedBy: User?
    let seasons: [Season]?

    struct Media: Decodable, Sendable {
        let tmdbId: Int?
        let mediaType: String?
        let status: Int?
    }

    struct User: Decodable, Sendable {
        let displayName: String?
        let username: String?
        let email: String?
    }

    struct Season: Decodable, Sendable {
        let seasonNumber: Int
    }
}

/// `/movie/{id}` and `/tv/{id}` – only the fields shown in the list.
struct SeerrMediaDetails: Decodable, Sendable {
    let title: String?
    let name: String?
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
}

struct SeerrSearchPage: Decodable, Sendable {
    let results: [SeerrSearchResult]
    let totalPages: Int?
}

struct SeerrGenre: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

/// `/network/{id}` – a TV network (Netflix, HBO …) with its TMDB logo.
struct SeerrNetwork: Sendable {
    let id: Int
    let name: String
    let logoURL: URL?
}

private struct SeerrNetworkResponse: Decodable {
    let id: Int
    let name: String
    let logoPath: String?
}

// MARK: - Discover queries

enum DiscoverSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case popularity, newest, rating

    var id: String { rawValue }
    var label: String {
        switch self {
        case .popularity: String(localized: "Popular")
        case .newest: String(localized: "Newest")
        case .rating: String(localized: "Top Rated")
        }
    }
}

/// One discover list: where it comes from plus optional sort/genre/network filters.
struct DiscoverQuery: Hashable, Sendable {
    enum Source: Hashable, Sendable { case trending, movies, tv, upcomingMovies, upcomingTV }

    var source: Source
    var title: String
    var sort: DiscoverSort = .popularity
    var genre: SeerrGenre? = nil
    var networkID: Int? = nil

    /// Only movie/series lists can be sorted and filtered by genre.
    var isFilterable: Bool { source == .movies || source == .tv }
    var mediaType: SeerrMediaType? {
        switch source {
        case .movies, .upcomingMovies: .movie
        case .tv, .upcomingTV: .tv
        case .trending: nil
        }
    }
}

// MARK: - Title details (detail page)

struct SeerrSeason: Identifiable, Hashable, Sendable {
    var id: Int { number }
    let number: Int
    let name: String
    let episodeCount: Int
    let airYear: String?
    /// Availability of this season on your server, if Seerr knows it.
    let state: SeerrState?
}

struct SeerrEpisode: Identifiable, Sendable {
    let id: Int
    let number: Int
    let name: String
    let airDate: Date?
    let overview: String?
    let stillURL: URL?
}

struct SeerrTitleDetails: Sendable {
    let tmdbID: Int
    let mediaType: SeerrMediaType
    let title: String
    let year: String?
    let tagline: String?
    let overview: String?
    let posterURL: URL?
    let backdropURL: URL?
    /// Minutes (movie runtime or typical episode length).
    let runtime: Int?
    let genres: [String]
    /// TMDB user score, 0–10.
    let tmdbScore: Double?
    let state: SeerrState?
    /// Regular seasons first, specials (season 0) last.
    let seasons: [SeerrSeason]
}

struct SeerrRatings: Sendable {
    var imdbScore: Double?
    var imdbVotes: Int?
    var imdbURL: URL?
    var criticsScore: Int?
    var criticsRating: String?
    var audienceScore: Int?
    var rottenTomatoesURL: URL?

    var isEmpty: Bool { imdbScore == nil && criticsScore == nil && audienceScore == nil }
}

/// A Radarr/Sonarr server as configured in Seerr, with its quality profiles.
struct SeerrArrServer: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let is4k: Bool
    let isDefault: Bool
    let defaultProfileID: Int?
    let profiles: [SeerrProfile]
}

struct SeerrProfile: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

/// Choices made on the detail page before requesting.
struct SeerrRequestOptions: Sendable {
    /// nil = all seasons (series only).
    var seasons: [Int]? = nil
    var server: SeerrArrServer? = nil
    var profileID: Int? = nil
}

private struct SeerrDetailsResponse: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let tagline: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let genres: [SeerrGenre]?
    let voteAverage: Double?
    let mediaInfo: MediaInfo?
    let seasons: [Season]?

    struct MediaInfo: Decodable {
        let status: Int?
        let seasons: [SeasonStatus]?
    }

    struct SeasonStatus: Decodable {
        let seasonNumber: Int
        let status: Int?
    }

    struct Season: Decodable {
        let seasonNumber: Int
        let name: String?
        let episodeCount: Int?
        let airDate: String?
    }
}

private struct SeerrSeasonResponse: Decodable {
    let episodes: [Episode]

    struct Episode: Decodable {
        let id: Int
        let episodeNumber: Int
        let name: String?
        let airDate: String?
        let overview: String?
        let stillPath: String?
    }
}

private struct SeerrRTRating: Decodable {
    let criticsScore: Int?
    let criticsRating: String?
    let audienceScore: Int?
    let url: String?
}

private struct SeerrIMDbRating: Decodable {
    let criticsScore: Double?
    let criticsScoreCount: Int?
    let url: String?
}

private struct SeerrCombinedRatings: Decodable {
    let rt: SeerrRTRating?
    let imdb: SeerrIMDbRating?
}

private struct SeerrServiceSummary: Decodable {
    let id: Int
    let name: String
    let is4k: Bool?
    let isDefault: Bool?
    let activeProfileId: Int?
}

private struct SeerrServiceDetails: Decodable {
    let profiles: [Profile]

    struct Profile: Decodable {
        let id: Int
        let name: String
    }
}

/// Where a title can be streamed in one country (TMDB watch providers, data by JustWatch).
struct StreamingProvider: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let logoURL: URL?
}

struct StreamingAvailability: Sendable {
    let region: String
    /// Included with a subscription (Netflix, Prime Video …).
    let subscription: [StreamingProvider]
    /// To buy (Apple TV, Amazon Video …).
    let purchase: [StreamingProvider]
}

/// `watchProviders` of `/movie/{id}` and `/tv/{id}`.
private struct SeerrWatchDetails: Decodable {
    let watchProviders: [Region]?

    struct Region: Decodable {
        let iso_3166_1: String
        let buy: [Provider]?
        let flatrate: [Provider]?
    }

    struct Provider: Decodable {
        let id: Int
        let name: String
        let logoPath: String?
        let displayPriority: Int?
    }
}

private actor StreamingCache {
    static let shared = StreamingCache()
    private var storage: [String: StreamingAvailability] = [:]
    func value(_ key: String) -> StreamingAvailability? { storage[key] }
    func set(_ value: StreamingAvailability, _ key: String) { storage[key] = value }
}

struct DiscoverPage: Sendable {
    let items: [DiscoverItem]
    let totalPages: Int
}

struct SeerrSearchResult: Decodable, Sendable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
    let mediaInfo: MediaInfo?

    struct MediaInfo: Decodable, Sendable {
        let status: Int?
    }
}

// MARK: - Display types

enum SeerrMediaType: String, Codable, Sendable {
    case movie, tv

    /// Singular chip label ("Movie" / "Series" in English, "Film" / "Serie" in German).
    var label: String {
        self == .movie ? String(localized: "media.movie", defaultValue: "Movie")
                       : String(localized: "media.series", defaultValue: "Series")
    }
    var systemImage: String { self == .movie ? "film" : "tv" }
    var kind: SeerrArtKind { self == .movie ? .movie : .series }
}

/// Combined request + media state, as shown on a request badge.
enum SeerrState: Sendable {
    case pendingApproval, declined, failed, processing, partiallyAvailable, available, unknown

    init(requestStatus: Int, mediaStatus: Int?) {
        switch requestStatus {
        case 1: self = .pendingApproval
        case 3: self = .declined
        case 4: self = .failed
        default:
            switch mediaStatus {
            case 5: self = .available
            case 4: self = .partiallyAvailable
            case 2, 3: self = .processing
            default: self = requestStatus == 5 ? .available : .processing
            }
        }
    }

    /// For search results: state of media that may never have been requested.
    init?(mediaStatus: Int?) {
        switch mediaStatus {
        case 2: self = .pendingApproval
        case 3: self = .processing
        case 4: self = .partiallyAvailable
        case 5: self = .available
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .pendingApproval: String(localized: "Pending")
        case .declined: String(localized: "Declined")
        case .failed: String(localized: "Failed")
        case .processing: String(localized: "Processing")
        case .partiallyAvailable: String(localized: "Partially Available")
        case .available: String(localized: "Available")
        case .unknown: String(localized: "Unknown")
        }
    }

    var color: Color {
        switch self {
        case .pendingApproval: .orange
        case .declined, .failed: .red
        case .processing: .blue
        case .partiallyAvailable, .available: .green
        case .unknown: .gray
        }
    }
}

struct RequestItem: Identifiable, Sendable {
    var id: Int { requestID }
    let requestID: Int
    let mediaType: SeerrMediaType
    let tmdbID: Int
    let title: String
    let year: String?
    let posterURL: URL?
    let overview: String?
    let requestedBy: String
    let createdAt: Date?
    let state: SeerrState
    let seasons: [Int]
    let is4k: Bool
}

struct DiscoverItem: Identifiable, Hashable, Sendable {
    var id: String { "\(mediaType.rawValue)-\(tmdbID)" }
    let tmdbID: Int
    let mediaType: SeerrMediaType
    let title: String
    let year: String?
    let posterURL: URL?
    let overview: String?
    let state: SeerrState?
}

enum TMDB {
    static func posterURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500" + path)
    }

    static func year(_ date: String?) -> String? {
        guard let date, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }
}

// MARK: - Service

enum SeerrDates {
    static func date(_ string: String?) -> Date? {
        guard let string, string.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(string.prefix(10)))
    }
}

/// Titles and posters aren't part of the request list, so details are fetched once per title and kept for the session.
private actor SeerrDetailsCache {
    static let shared = SeerrDetailsCache()
    private var storage: [String: SeerrMediaDetails] = [:]

    func value(for key: String) -> SeerrMediaDetails? { storage[key] }
    func set(_ value: SeerrMediaDetails, for key: String) { storage[key] = value }
}

struct SeerrClient: Sendable {
    let config: SeerrConfig

    func status() async throws -> String {
        let status: SeerrStatus = try await get("/api/v1/status")
        return status.version
    }

    func requests() async throws -> [RequestItem] {
        let page: SeerrRequestPage = try await get("/api/v1/request", query: [
            ("take", "50"), ("skip", "0"), ("sort", "added"), ("filter", "all"),
        ])
        return try await withThrowingTaskGroup(of: (Int, RequestItem?).self) { group in
            for (index, request) in page.results.enumerated() {
                group.addTask {
                    guard let tmdbID = request.media.tmdbId,
                          let type = SeerrMediaType(rawValue: request.type ?? request.media.mediaType ?? "")
                    else { return (index, nil) }
                    let details = try? await details(type: type, tmdbID: tmdbID)
                    let user = request.requestedBy
                    return (index, RequestItem(
                        requestID: request.id,
                        mediaType: type,
                        tmdbID: tmdbID,
                        title: details?.title ?? details?.name ?? "TMDB \(tmdbID)",
                        year: TMDB.year(details?.releaseDate ?? details?.firstAirDate),
                        posterURL: TMDB.posterURL(details?.posterPath),
                        overview: details?.overview,
                        requestedBy: user?.displayName ?? user?.username ?? user?.email ?? String(localized: "Unknown"),
                        createdAt: request.createdAt,
                        state: SeerrState(requestStatus: request.status, mediaStatus: request.media.status),
                        seasons: (request.seasons ?? []).map(\.seasonNumber).sorted(),
                        is4k: request.is4k ?? false
                    ))
                }
            }
            var items: [(Int, RequestItem)] = []
            for try await (index, item) in group {
                if let item { items.append((index, item)) }
            }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func approve(requestID: Int) async throws {
        _ = try await send("/api/v1/request/\(requestID)/approve", method: "POST")
    }

    func decline(requestID: Int) async throws {
        _ = try await send("/api/v1/request/\(requestID)/decline", method: "POST")
    }

    func delete(requestID: Int) async throws {
        _ = try await send("/api/v1/request/\(requestID)", method: "DELETE")
    }

    func search(_ query: String) async throws -> [DiscoverItem] {
        let page: SeerrSearchPage = try await get("/api/v1/search", query: [("query", query), ("page", "1")])
        return discoverItems(from: page)
    }

    func trending() async throws -> [DiscoverItem] {
        let page: SeerrSearchPage = try await get("/api/v1/discover/trending", query: [("page", "1")])
        return discoverItems(from: page)
    }

    func discover(_ query: DiscoverQuery, page: Int) async throws -> DiscoverPage {
        var params: [(String, String)] = [("page", String(page))]
        let path: String
        let today = Date.now.formatted(.iso8601.year().month().day())
        switch query.source {
        case .trending:
            path = "/api/v1/discover/trending"
        case .upcomingMovies:
            path = "/api/v1/discover/movies/upcoming"
        case .upcomingTV:
            path = "/api/v1/discover/tv/upcoming"
        case .movies:
            path = "/api/v1/discover/movies"
            switch query.sort {
            case .popularity: params.append(("sortBy", "popularity.desc"))
            case .newest: params += [("sortBy", "primary_release_date.desc"), ("primaryReleaseDateLte", today), ("voteCountGte", "20")]
            case .rating: params += [("sortBy", "vote_average.desc"), ("voteCountGte", "1000")]
            }
            if let genre = query.genre { params.append(("genre", String(genre.id))) }
        case .tv:
            path = "/api/v1/discover/tv"
            switch query.sort {
            case .popularity: params.append(("sortBy", "popularity.desc"))
            case .newest: params += [("sortBy", "first_air_date.desc"), ("firstAirDateLte", today), ("voteCountGte", "10")]
            case .rating: params += [("sortBy", "vote_average.desc"), ("voteCountGte", "500")]
            }
            if let genre = query.genre { params.append(("genre", String(genre.id))) }
            if let network = query.networkID { params.append(("network", String(network))) }
        }
        let result: SeerrSearchPage = try await get(path, query: params)
        return DiscoverPage(items: discoverItems(from: result), totalPages: max(1, result.totalPages ?? 1))
    }

    /// Movies or series from Seerr's discover endpoint with any TMDB filters (genre, keywords,
    /// original language via `language`, dates, votes, sort).
    func discover(_ type: SeerrMediaType, filters: [(String, String)], page: Int = 1) async throws -> [DiscoverItem] {
        let path = type == .movie ? "/api/v1/discover/movies" : "/api/v1/discover/tv"
        let result: SeerrSearchPage = try await get(path, query: [("page", String(page))] + filters)
        return discoverItems(from: result)
    }

    /// TMDB keyword id for a name ("based on true story" → 9672), via Seerr's keyword search.
    func keywordID(_ name: String) async throws -> Int? {
        struct Keyword: Decodable { let id: Int; let name: String }
        struct KeywordPage: Decodable { let results: [Keyword] }
        let page: KeywordPage = try await get("/api/v1/search/keyword", query: [("query", name), ("page", "1")])
        return page.results.first { $0.name.lowercased() == name.lowercased() }?.id ?? page.results.first?.id
    }

    func genres(_ type: SeerrMediaType) async throws -> [SeerrGenre] {
        try await get("/api/v1/genres/\(type.rawValue)")
    }

    func streaming(_ type: SeerrMediaType, tmdbID: Int, region: String) async throws -> StreamingAvailability {
        let key = "\(config.baseURL)-\(type.rawValue)-\(tmdbID)-\(region)"
        if let cached = await StreamingCache.shared.value(key) { return cached }
        let details: SeerrWatchDetails = try await get("/api/v1/\(type.rawValue)/\(tmdbID)")
        let country = details.watchProviders?.first { $0.iso_3166_1.uppercased() == region.uppercased() }
        func providers(_ list: [SeerrWatchDetails.Provider]?) -> [StreamingProvider] {
            (list ?? []).sorted { ($0.displayPriority ?? 999) < ($1.displayPriority ?? 999) }.map {
                StreamingProvider(id: $0.id, name: $0.name,
                                  logoURL: $0.logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w92" + $0) })
            }
        }
        let availability = StreamingAvailability(region: region, subscription: providers(country?.flatrate),
                                                 purchase: providers(country?.buy))
        await StreamingCache.shared.set(availability, key)
        return availability
    }

    func network(id: Int) async throws -> SeerrNetwork {
        let network: SeerrNetworkResponse = try await get("/api/v1/network/\(id)")
        // TMDB network logos are transparent PNGs.
        let logo = network.logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w300" + $0) }
        return SeerrNetwork(id: network.id, name: network.name, logoURL: logo)
    }

    private func discoverItems(from page: SeerrSearchPage) -> [DiscoverItem] {
        page.results.compactMap { result in
            guard let type = SeerrMediaType(rawValue: result.mediaType) else { return nil } // skips people
            return DiscoverItem(
                tmdbID: result.id,
                mediaType: type,
                title: result.title ?? result.name ?? String(localized: "Untitled"),
                year: TMDB.year(result.releaseDate ?? result.firstAirDate),
                posterURL: TMDB.posterURL(result.posterPath),
                overview: result.overview,
                state: SeerrState(mediaStatus: result.mediaInfo?.status)
            )
        }
    }

    /// Requests with Seerr's defaults (all seasons, default server and profile).
    func request(_ item: DiscoverItem) async throws {
        try await request(item, options: SeerrRequestOptions())
    }

    func request(_ item: DiscoverItem, options: SeerrRequestOptions) async throws {
        var body: [String: Any] = ["mediaType": item.mediaType.rawValue, "mediaId": item.tmdbID]
        if item.mediaType == .tv {
            if let seasons = options.seasons { body["seasons"] = seasons } else { body["seasons"] = "all" }
        }
        if let server = options.server {
            body["serverId"] = server.id
            body["is4k"] = server.is4k
        }
        if let profileID = options.profileID { body["profileId"] = profileID }
        _ = try await send("/api/v1/request", method: "POST", json: body)
    }

    func details(_ type: SeerrMediaType, tmdbID: Int) async throws -> SeerrTitleDetails {
        let response: SeerrDetailsResponse = try await get("/api/v1/\(type.rawValue)/\(tmdbID)")
        let seasonStates = Dictionary((response.mediaInfo?.seasons ?? []).map { ($0.seasonNumber, $0.status) },
                                      uniquingKeysWith: { first, _ in first })
        let seasons = (response.seasons ?? [])
            .map { season in
                SeerrSeason(number: season.seasonNumber,
                            name: season.name ?? (season.seasonNumber == 0 ? String(localized: "Specials") : String(localized: "Season \(season.seasonNumber)")),
                            episodeCount: season.episodeCount ?? 0,
                            airYear: TMDB.year(season.airDate),
                            state: SeerrState(mediaStatus: seasonStates[season.seasonNumber] ?? nil))
            }
            .sorted { ($0.number == 0 ? Int.max : $0.number) < ($1.number == 0 ? Int.max : $1.number) }
        return SeerrTitleDetails(
            tmdbID: response.id,
            mediaType: type,
            title: response.title ?? response.name ?? String(localized: "Untitled"),
            year: TMDB.year(response.releaseDate ?? response.firstAirDate),
            tagline: response.tagline?.isEmpty == false ? response.tagline : nil,
            overview: response.overview,
            posterURL: TMDB.posterURL(response.posterPath),
            backdropURL: response.backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w780" + $0) },
            runtime: response.runtime ?? response.episodeRunTime?.first,
            genres: (response.genres ?? []).map(\.name),
            tmdbScore: response.voteAverage.flatMap { $0 > 0 ? $0 : nil },
            state: SeerrState(mediaStatus: response.mediaInfo?.status),
            seasons: seasons)
    }

    func episodes(tmdbID: Int, season: Int) async throws -> [SeerrEpisode] {
        let response: SeerrSeasonResponse = try await get("/api/v1/tv/\(tmdbID)/season/\(season)")
        return response.episodes.map { episode in
            SeerrEpisode(id: episode.id, number: episode.episodeNumber,
                         name: episode.name ?? String(localized: "Episode \(episode.episodeNumber)"),
                         airDate: SeerrDates.date(episode.airDate),
                         overview: episode.overview?.isEmpty == false ? episode.overview : nil,
                         stillURL: episode.stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w300" + $0) })
        }
    }

    func ratings(_ type: SeerrMediaType, tmdbID: Int) async throws -> SeerrRatings {
        func rt(_ rating: SeerrRTRating?, into result: inout SeerrRatings) {
            guard let rating else { return }
            result.criticsScore = rating.criticsScore
            result.criticsRating = rating.criticsRating
            result.audienceScore = rating.audienceScore
            result.rottenTomatoesURL = rating.url.flatMap(URL.init(string:))
        }
        var result = SeerrRatings()
        do {
            if type == .movie {
                let combined: SeerrCombinedRatings = try await get("/api/v1/movie/\(tmdbID)/ratingscombined")
                rt(combined.rt, into: &result)
                result.imdbScore = combined.imdb?.criticsScore
                result.imdbVotes = combined.imdb?.criticsScoreCount
                result.imdbURL = combined.imdb?.url.flatMap(URL.init(string:))
            } else {
                let rating: SeerrRTRating = try await get("/api/v1/tv/\(tmdbID)/ratings")
                rt(rating, into: &result)
            }
        } catch SeerrError.http(404) {
            // Seerr answers 404 when no rating site knows the title.
        }
        return result
    }

    func arrServers(for type: SeerrMediaType) async throws -> [SeerrArrServer] {
        let service = type == .movie ? "radarr" : "sonarr"
        let summaries: [SeerrServiceSummary] = try await get("/api/v1/service/\(service)")
        return try await withThrowingTaskGroup(of: SeerrArrServer.self) { group in
            for summary in summaries {
                group.addTask {
                    let details: SeerrServiceDetails = try await get("/api/v1/service/\(service)/\(summary.id)")
                    return SeerrArrServer(id: summary.id, name: summary.name, is4k: summary.is4k ?? false,
                                          isDefault: summary.isDefault ?? false, defaultProfileID: summary.activeProfileId,
                                          profiles: details.profiles.map { SeerrProfile(id: $0.id, name: $0.name) })
                }
            }
            var servers: [SeerrArrServer] = []
            for try await server in group { servers.append(server) }
            // Default server first, 4K servers after regular ones.
            return servers.sorted { ($0.isDefault ? 0 : 1, $0.is4k ? 1 : 0, $0.name) < ($1.isDefault ? 0 : 1, $1.is4k ? 1 : 0, $1.name) }
        }
    }

    // MARK: Private

    private func details(type: SeerrMediaType, tmdbID: Int) async throws -> SeerrMediaDetails {
        let key = "\(config.baseURL)-\(type.rawValue)-\(tmdbID)"
        if let cached = await SeerrDetailsCache.shared.value(for: key) { return cached }
        let details: SeerrMediaDetails = try await get("/api/v1/\(type.rawValue)/\(tmdbID)")
        await SeerrDetailsCache.shared.set(details, for: key)
        return details
    }

    private func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        try SeerrJSON.decoder.decode(T.self, from: try await send(path, query: query))
    }

    func send(_ path: String, method: String = "GET", query: [(String, String)] = [], json: Any? = nil) async throws -> Data {
        let url = try SeerrHTTP.url(base: config.baseURL, path: path, query: query)
        return try await SeerrHTTP.send(url, method: method, headers: ["X-Api-Key": config.apiKey], json: json)
    }
}

/// Streaming services and channels shown under "Networks" (TMDB network IDs, same as Seerr's own slider).
enum DiscoverNetworks {
    static let all: [(id: Int, name: String)] = [
        (213, "Netflix"), (2739, "Disney+"), (1024, "Prime Video"), (2552, "Apple TV+"), (3186, "HBO Max"),
        (49, "HBO"), (453, "Hulu"), (4330, "Paramount+"), (3353, "Peacock"),
    ]

    static func fallbackName(_ id: Int) -> String {
        all.first { $0.id == id }?.name ?? String(localized: "Network")
    }
}

// MARK: - HTTP

enum SeerrError: LocalizedError {
    case invalidURL
    case badResponse
    case unauthorized
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "The Seerr address is not valid.")
        case .badResponse: String(localized: "Seerr sent an unexpected response.")
        case .unauthorized: String(localized: "Seerr rejected the API key. Find it in Seerr under Settings → General → API Key.")
        case .http(let code): String(localized: "Seerr returned HTTP \(code).")
        }
    }
}

/// URL building and requests for the Seerr client.
enum SeerrHTTP {
    /// Characters left unescaped in query values (RFC 3986 unreserved). Seerr rejects
    /// search queries with raw reserved characters, so everything else is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func url(base: String, path: String, query: [(String, String)] = []) throws -> URL {
        var string = base + path
        if !query.isEmpty {
            string += "?" + query.map { name, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(name)=\(encoded)"
            }.joined(separator: "&")
        }
        guard let url = URL(string: string), url.host != nil else { throw SeerrError.invalidURL }
        return url
    }

    static func send(_ url: URL, method: String = "GET", headers: [String: String] = [:], json body: Any? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrError.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw SeerrError.unauthorized
        default: throw SeerrError.http(http.statusCode)
        }
    }
}

enum SeerrJSON {
    /// Seerr dates come both with and without fractional seconds.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(string)")
        }
        return decoder
    }()
}
