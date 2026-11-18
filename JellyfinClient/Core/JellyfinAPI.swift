import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case forbidden
    case http(status: Int, message: String?)
    case playback(code: String)
    case noPlayableSource

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Wrong username or password, or your session has expired.")
        case .forbidden:
            return String(localized: "Your Jellyfin user isn't allowed to do this. Ask the server admin to enable the permission (e.g. transcoding or downloads).")
        case let .http(status, message):
            let detail = message.flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
            return String(localized: "Server error \(status)") + (detail.map { ": \($0)" } ?? "")
        case let .playback(code):
            switch code {
            case "NotAllowed": return String(localized: "Playback isn't allowed for this user.")
            case "NoCompatibleStream": return String(localized: "The server found no stream this iPhone can play.")
            case "RateLimitExceeded": return String(localized: "The server's streaming limit was reached.")
            default: return String(localized: "Playback error: \(code)")
            }
        case .noPlayableSource:
            return String(localized: "No playable media source was returned by the server.")
        }
    }
}

enum JSONCoding {
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(key.prefix(1).uppercased() + key.dropFirst())
        }
        return encoder
    }()
}

/// Thin async/await client for the Jellyfin REST API (server 10.9+).
struct JellyfinAPI {
    static let clientName = "JellyfinClient"
    static let clientVersion = "0.1.0"
    static let deviceName = "iPhone"

    static var deviceId: String {
        let key = "jellyfin.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static let listFields = "PrimaryImageAspectRatio,Overview,MediaSources,Genres"

    let baseURL: URL
    var accessToken: String?
    var userId: String?

    init(baseURL: URL, accessToken: String? = nil, userId: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.userId = userId
    }

    init(session: ServerSession) {
        self.init(baseURL: session.serverURL, accessToken: session.accessToken, userId: session.userId)
    }

    var authorizationHeader: String {
        var value = "MediaBrowser Client=\"\(Self.clientName)\", Device=\"\(Self.deviceName)\", DeviceId=\"\(Self.deviceId)\", Version=\"\(Self.clientVersion)\""
        if let accessToken { value += ", Token=\"\(accessToken)\"" }
        return value
    }

    // MARK: - URL building

    func url(_ path: String, _ query: [String: String?] = [:]) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        guard !items.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = items.sorted { $0.name < $1.name }
        return comps.url ?? url
    }

    /// Resolves a server-relative URL such as a `TranscodingUrl` against the base URL (keeps any base path).
    func absoluteURL(serverRelative path: String) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + (path.hasPrefix("/") ? path : "/" + path))
    }

    // MARK: - Requests

    @discardableResult
    func sendRaw(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200..<300: return data
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        default: throw APIError.http(status: status, message: String(data: data, encoding: .utf8))
        }
    }

    func send<T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil) async throws -> T {
        let data = try await sendRaw(method, path, query: query, body: body)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:]) async throws -> T {
        try await send("GET", path, query: query)
    }

    // MARK: - Auth

    func publicSystemInfo() async throws -> PublicSystemInfo {
        try await get("System/Info/Public")
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        struct Body: Encodable { let username: String; let pw: String }
        let body = try JSONCoding.encoder.encode(Body(username: username, pw: password))
        return try await send("POST", "Users/AuthenticateByName", body: body)
    }

    func logout() async throws {
        try await sendRaw("POST", "Sessions/Logout")
    }

    // MARK: - Browsing

    func userViews() async throws -> [BaseItem] {
        let result: ItemsResult = try await get("UserViews", ["userId": userId])
        return result.items
    }

    func resumeItems() async throws -> [BaseItem] {
        let result: ItemsResult = try await get("UserItems/Resume", [
            "userId": userId, "limit": "20", "mediaTypes": "Video", "fields": Self.listFields,
        ])
        return result.items
    }

    func items(in parent: BaseItem, startIndex: Int, limit: Int) async throws -> ItemsResult {
        var query: [String: String?] = [
            "userId": userId, "parentId": parent.id,
            "startIndex": String(startIndex), "limit": String(limit),
            "sortBy": "SortName", "sortOrder": "Ascending",
            "fields": Self.listFields, "enableTotalRecordCount": "true",
        ]
        switch parent.collectionType {
        case "movies": query["includeItemTypes"] = "Movie"; query["recursive"] = "true"
        case "tvshows": query["includeItemTypes"] = "Series"; query["recursive"] = "true"
        case "boxsets": query["includeItemTypes"] = "BoxSet"; query["recursive"] = "true"
        default: break
        }
        return try await get("Items", query)
    }

    /// Movies and series in the user's libraries matching `term`, with provider IDs to tell them apart from Seerr results.
    func searchItems(_ term: String, limit: Int = 50) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Items", [
            "userId": userId, "searchTerm": term, "recursive": "true",
            "includeItemTypes": "Movie,Series", "limit": String(limit),
            "fields": Self.listFields + ",ProviderIds,OriginalTitle", "enableTotalRecordCount": "false",
        ])
        return result.items
    }

    /// Genres used in the library for movies or series, with how many titles each has.
    func genres(itemType: String) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Genres", [
            "userId": userId, "includeItemTypes": itemType, "recursive": "true", "fields": "ItemCounts",
            "enableTotalRecordCount": "false",
        ])
        return result.items
    }

    /// Movies or series of one genre from the library, in random order.
    func items(genre: String, itemType: String, limit: Int = 20) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Items", [
            "userId": userId, "genres": genre, "includeItemTypes": itemType, "recursive": "true",
            "sortBy": "Random", "limit": String(limit), "fields": "PrimaryImageAspectRatio,ProductionYear",
            "enableTotalRecordCount": "false",
        ])
        return result.items
    }

    /// The library copy of a TMDB title (for Seerr items that are available): title search, then the
    /// TMDB id must match.
    func libraryItem(tmdbID: Int, title: String, isSeries: Bool) async -> BaseItem? {
        let results = (try? await searchItems(title, limit: 20)) ?? []
        return results.first { $0.type == (isSeries ? "Series" : "Movie") && $0.providerID("Tmdb") == String(tmdbID) }
    }

    /// The user's favorite movies, series and episodes.
    func favoriteItems() async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Items", [
            "userId": userId, "recursive": "true", "filters": "IsFavorite",
            "includeItemTypes": "Movie,Series,Episode", "sortBy": "SortName", "sortOrder": "Ascending",
            "fields": Self.listFields, "limit": "500",
        ])
        return result.items
    }

    func item(id: String) async throws -> BaseItem {
        try await get("Items/\(id)", ["userId": userId])
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Shows/\(seriesId)/Seasons", ["userId": userId])
        return result.items
    }

    func episodes(seriesId: String, seasonId: String? = nil) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Shows/\(seriesId)/Episodes", [
            "userId": userId, "seasonId": seasonId, "fields": Self.listFields,
        ])
        return result.items
    }

    /// The episodes of a series that are really on the server (not Jellyfin's placeholders for missing ones),
    /// with just their season and episode numbers.
    func ownedEpisodes(seriesId: String) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Shows/\(seriesId)/Episodes", [
            "userId": userId, "isMissing": "false", "enableImages": "false", "enableUserData": "false",
        ])
        return result.items
    }

    /// Next episodes to watch, across all series or for one series.
    /// - Parameter includeResumable: also return partly watched episodes (off for the home row,
    ///   where those already appear under "Continue Watching").
    func nextUp(seriesId: String? = nil, limit: Int = 20, includeResumable: Bool = true) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Shows/NextUp", [
            "userId": userId, "seriesId": seriesId, "limit": String(limit), "fields": Self.listFields,
            "enableResumable": includeResumable ? "true" : "false",
        ])
        return result.items
    }

    /// The episode a series' play button should start: next up, otherwise the first regular episode.
    func episodeToPlay(seriesId: String) async throws -> BaseItem? {
        if let next = try await nextUp(seriesId: seriesId, limit: 1).first { return next }
        let all = try await episodes(seriesId: seriesId)
        return all.first { ($0.parentIndexNumber ?? 1) > 0 } ?? all.first
    }

    /// Newest additions to a library (`/Items/Latest` returns a plain array).
    func latest(parentId: String, limit: Int = 16) async throws -> [BaseItem] {
        try await get("Items/Latest", [
            "userId": userId, "parentId": parentId, "limit": String(limit),
            "fields": "PrimaryImageAspectRatio,Overview,Genres", "groupItems": "true",
        ])
    }

    /// Newest additions to a TV library as whole series: new episodes/seasons are mapped to their series
    /// (newest first, each series once). Jellyfin's own grouping only merges some of them.
    func latestSeries(parentId: String, limit: Int = 16) async throws -> [BaseItem] {
        let recent = try await latest(parentId: parentId, limit: 60)
        var seen = Set<String>()
        let seriesIds = recent.compactMap { item -> String? in
            let id = item.type == "Series" ? item.id : item.seriesId
            guard let id, seen.insert(id).inserted else { return nil }
            return id
        }.prefix(limit)
        guard !seriesIds.isEmpty else { return [] }
        let result: ItemsResult = try await get("Items", [
            "userId": userId, "ids": seriesIds.joined(separator: ","),
            "fields": "PrimaryImageAspectRatio,Overview,Genres",
        ])
        let byId = Dictionary(result.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return seriesIds.compactMap { byId[$0] }
    }

    func similar(itemId: String, limit: Int = 12) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Items/\(itemId)/Similar", [
            "userId": userId, "limit": String(limit), "fields": "PrimaryImageAspectRatio",
        ])
        return result.items
    }

    func localTrailers(itemId: String) async throws -> [BaseItem] {
        try await get("Items/\(itemId)/LocalTrailers", ["userId": userId])
    }

    /// Marks an item (or a whole series) as watched or not watched; both clear the playback position.
    @discardableResult
    func setPlayed(itemId: String, _ played: Bool) async throws -> UserItemData {
        try await send(played ? "POST" : "DELETE", "UserPlayedItems/\(itemId)", query: ["userId": userId])
    }

    @discardableResult
    func setFavorite(itemId: String, _ favorite: Bool) async throws -> UserItemData {
        try await send(favorite ? "POST" : "DELETE", "UserFavoriteItems/\(itemId)", query: ["userId": userId])
    }

    // MARK: - Images

    func imageURL(itemId: String, type: String, tag: String?, maxWidth: Int) -> URL {
        url("Items/\(itemId)/Images/\(type)", ["maxWidth": String(maxWidth), "quality": "90", "tag": tag])
    }

    func posterURL(for item: BaseItem, maxWidth: Int = 300) -> URL? {
        item.imageTag("Primary").map { imageURL(itemId: item.id, type: "Primary", tag: $0, maxWidth: maxWidth) }
    }

    /// Poster for rows that mix movies and episodes: episodes show their series' poster instead of the episode still.
    func seriesOrItemPosterURL(for item: BaseItem, maxWidth: Int = 300) -> URL? {
        if item.type == "Episode", let seriesId = item.seriesId {
            return imageURL(itemId: seriesId, type: "Primary", tag: item.seriesPrimaryImageTag, maxWidth: maxWidth)
        }
        return posterURL(for: item, maxWidth: maxWidth)
    }

    /// Title logo (transparent PNG): the item's own, or the series' logo for episodes.
    func logoURL(for item: BaseItem, maxWidth: Int = 600) -> URL? {
        if let tag = item.imageTag("Logo") {
            return imageURL(itemId: item.id, type: "Logo", tag: tag, maxWidth: maxWidth)
        }
        if let parent = item.parentLogoItemId, let tag = item.parentLogoImageTag {
            return imageURL(itemId: parent, type: "Logo", tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    /// Big hero artwork: the item's (or its series') backdrop, never an episode still.
    func heroBackdropURL(for item: BaseItem, maxWidth: Int = 1920) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemId: item.id, type: "Backdrop", tag: tag, maxWidth: maxWidth)
        }
        if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: parent, type: "Backdrop", tag: tag, maxWidth: maxWidth)
        }
        return posterURL(for: item, maxWidth: maxWidth)
    }

    /// Landscape series/movie artwork for "Continue Watching" (no episode stills).
    /// `needsLogo` is true when the art is a plain backdrop, so the caller should overlay the title logo.
    func landscapeArt(for item: BaseItem, maxWidth: Int = 800) -> (url: URL?, needsLogo: Bool) {
        if item.type == "Episode" {
            if let parent = item.parentThumbItemId, let tag = item.parentThumbImageTag {
                return (imageURL(itemId: parent, type: "Thumb", tag: tag, maxWidth: maxWidth), false)
            }
            if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
                return (imageURL(itemId: parent, type: "Backdrop", tag: tag, maxWidth: maxWidth), true)
            }
            return (seriesOrItemPosterURL(for: item, maxWidth: maxWidth), false)
        }
        if let tag = item.imageTag("Thumb") {
            return (imageURL(itemId: item.id, type: "Thumb", tag: tag, maxWidth: maxWidth), false)
        }
        if let tag = item.backdropImageTags?.first {
            return (imageURL(itemId: item.id, type: "Backdrop", tag: tag, maxWidth: maxWidth), true)
        }
        return (posterURL(for: item, maxWidth: maxWidth), false)
    }

    /// Landscape artwork: own backdrop, then parent's backdrop, then thumb, then primary.
    func backdropURL(for item: BaseItem, maxWidth: Int = 1280) -> URL? {
        if item.type == "Episode", let tag = item.imageTag("Primary") {
            return imageURL(itemId: item.id, type: "Primary", tag: tag, maxWidth: maxWidth)
        }
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemId: item.id, type: "Backdrop", tag: tag, maxWidth: maxWidth)
        }
        if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: parent, type: "Backdrop", tag: tag, maxWidth: maxWidth)
        }
        if let tag = item.imageTag("Thumb") {
            return imageURL(itemId: item.id, type: "Thumb", tag: tag, maxWidth: maxWidth)
        }
        if let parent = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return imageURL(itemId: parent, type: "Thumb", tag: tag, maxWidth: maxWidth)
        }
        return posterURL(for: item, maxWidth: maxWidth)
    }

    // MARK: - Playback

    func playbackInfo(itemId: String, maxBitrate: Int, player: PlayerKind, mediaSourceId: String? = nil,
                      selection: TrackSelection? = nil) async throws -> PlaybackInfoResponse {
        var body: [String: Any] = [
            "UserId": userId ?? "",
            "MaxStreamingBitrate": maxBitrate,
            "StartTimeTicks": 0,
            "DeviceProfile": DeviceProfile.make(maxBitrate: maxBitrate, player: player),
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": true,
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        if let selection {
            if let audio = selection.audioIndex { body["AudioStreamIndex"] = audio }
            body["SubtitleStreamIndex"] = selection.subtitleIndex ?? -1
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send("POST", "Items/\(itemId)/PlaybackInfo", query: ["userId": userId], body: data)
    }

    func directStreamURL(itemId: String, mediaSourceId: String?, container: String?, playSessionId: String?) -> URL {
        let ext = container?.split(separator: ",").first.map { ".\($0)" } ?? ""
        return url("Videos/\(itemId)/stream\(ext)", [
            "static": "true", "mediaSourceId": mediaSourceId, "deviceId": Self.deviceId,
            "playSessionId": playSessionId, "api_key": accessToken,
        ])
    }

    /// Adds the access token to a URL that doesn't already carry one.
    func withToken(_ url: URL) -> URL {
        guard let accessToken, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        let names = Set(items.map { $0.name.lowercased() })
        guard !names.contains("api_key"), !names.contains("apikey") else { return url }
        items.append(URLQueryItem(name: "api_key", value: accessToken))
        comps.queryItems = items
        return comps.url ?? url
    }

    /// A text subtitle as a standalone file (external subtitles, or embedded ones extracted by the server).
    func subtitleURL(itemId: String, mediaSourceId: String?, stream: MediaStream) -> URL? {
        if let delivery = stream.deliveryUrl, let resolved = absoluteURL(serverRelative: delivery) {
            return withToken(resolved)
        }
        guard stream.isTextSubtitle, let mediaSourceId else { return nil }
        let format: String
        switch (stream.codec ?? "").lowercased() {
        case "ass": format = "ass"
        case "ssa": format = "ssa"
        case "vtt", "webvtt": format = "vtt"
        default: format = "srt"
        }
        return url("Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(stream.index)/Stream.\(format)", ["api_key": accessToken])
    }

    struct PlaybackReport: Encodable {
        var itemId: String
        var mediaSourceId: String?
        var playSessionId: String?
        var positionTicks: Int64
        var isPaused: Bool
        var playMethod: String
        var audioStreamIndex: Int?
        var subtitleStreamIndex: Int?
        var canSeek = true
    }

    func reportPlayback(_ event: PlaybackEvent, _ report: PlaybackReport) async throws {
        try await sendRaw("POST", event.path, body: try JSONCoding.encoder.encode(report))
    }

    enum PlaybackEvent {
        case start, progress, stopped
        var path: String {
            switch self {
            case .start: return "Sessions/Playing"
            case .progress: return "Sessions/Playing/Progress"
            case .stopped: return "Sessions/Playing/Stopped"
            }
        }
    }

    /// Sets the resume position (and the watched flag) of an item, e.g. after watching a download offline.
    /// Jellyfin 10.9+ uses /UserItems/{id}/UserData; older servers /Users/{userId}/Items/{id}/UserData.
    func updatePlayState(itemId: String, positionTicks: Int64, played: Bool?, lastPlayed: Date) async throws {
        var body: [String: Any] = [
            "PlaybackPositionTicks": positionTicks,
            "LastPlayedDate": lastPlayed.formatted(.iso8601),
        ]
        if let played { body["Played"] = played }
        let data = try JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await sendRaw("POST", "UserItems/\(itemId)/UserData", query: ["userId": userId], body: data)
        } catch {
            guard let userId else { throw error }
            _ = try await sendRaw("POST", "Users/\(userId)/Items/\(itemId)/UserData", body: data)
        }
    }

    func stopTranscoding(playSessionId: String) async throws {
        try await sendRaw("DELETE", "Videos/ActiveEncodings", query: [
            "deviceId": Self.deviceId, "playSessionId": playSessionId,
        ])
    }

    // MARK: - Downloads

    /// The untouched original file (needs the "Allow media downloading" permission).
    func originalDownloadURL(itemId: String) -> URL {
        url("Items/\(itemId)/Download", ["api_key": accessToken])
    }

    /// A text subtitle as a file to download (external, or embedded and extracted by the server).
    func subtitleDownloadURL(itemId: String, mediaSourceId: String?, streamIndex: Int, codec: String?) -> URL? {
        guard let mediaSourceId else { return nil }
        let format: String
        switch (codec ?? "").lowercased() {
        case "ass": format = "ass"
        case "ssa": format = "ssa"
        case "vtt", "webvtt": format = "vtt"
        default: format = "srt"
        }
        return url("Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/Stream.\(format)", ["api_key": accessToken])
    }

    /// One audio track for an offline copy. Jellyfin's audio-only endpoint always takes the default
    /// track (it doesn't map streams), so this asks for a video transcode with the chosen audio and a
    /// tiny placeholder picture; mpv adds only its audio as an extra track.
    func audioTrackDownloadURL(itemId: String, mediaSourceId: String?, audioStreamIndex: Int, audioBitrate: Int) -> URL {
        url("Videos/\(itemId)/stream.mkv", [
            "mediaSourceId": mediaSourceId,
            "deviceId": Self.deviceId,
            "playSessionId": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "api_key": accessToken,
            "videoCodec": "h264",
            "videoBitRate": "48000",
            "maxWidth": "160",
            "maxHeight": "90",
            "maxFramerate": "5",
            "audioCodec": "aac",
            "audioBitRate": String(audioBitrate),
            "maxAudioChannels": "2",
            "audioStreamIndex": String(audioStreamIndex),
        ])
    }

    /// One audio track as HLS segments (with a tiny picture, as Jellyfin's HLS needs video), so the
    /// download continues after a dropped connection like the video does.
    func audioTrackHLSPlaylistURL(itemId: String, mediaSourceId: String?, audioStreamIndex: Int, audioBitrate: Int,
                                  playSessionId: String) -> URL {
        url("Videos/\(itemId)/main.m3u8", [
            "mediaSourceId": mediaSourceId,
            "deviceId": Self.deviceId,
            "playSessionId": playSessionId,
            "api_key": accessToken,
            "videoCodec": "h264",
            "videoBitRate": "48000",
            "maxWidth": "160",
            "maxHeight": "90",
            "maxFramerate": "5",
            "audioCodec": "aac",
            "audioBitRate": String(audioBitrate),
            "maxAudioChannels": "2",
            "audioStreamIndex": String(audioStreamIndex),
            "segmentContainer": "mp4",
            "segmentLength": String(Self.downloadSegmentSeconds),
            "allowVideoStreamCopy": "false",
            "breakOnNonKeyFrames": "false",
        ])
    }

    /// Audio bitrate used for transcoded downloads at this total bitrate.
    static func downloadAudioBitrate(forMbit mbit: Double) -> Int {
        Bitrate.bps(forMbit: mbit) >= 1_500_000 ? 192_000 : 128_000
    }

    /// Query for an H.264/AAC transcode at the given total bitrate.
    private func downloadTranscodeQuery(mediaSourceId: String?, mbit: Double, audioStreamIndex: Int?,
                                        playSessionId: String?) -> [String: String?] {
        let total = Bitrate.bps(forMbit: mbit)
        let audio = Self.downloadAudioBitrate(forMbit: mbit)
        let video = max(total - audio, 250_000)
        var query: [String: String?] = [
            "mediaSourceId": mediaSourceId,
            "deviceId": Self.deviceId,
            "playSessionId": playSessionId ?? UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "api_key": accessToken,
            "videoCodec": "h264",
            "audioCodec": "aac",
            "videoBitRate": String(video),
            "audioBitRate": String(audio),
            "maxAudioChannels": "2",
        ]
        if let audioStreamIndex { query["audioStreamIndex"] = String(audioStreamIndex) }
        if let width = Bitrate.maxWidth(forMbit: mbit) { query["maxWidth"] = String(width) }
        return query
    }

    /// A progressive H.264/AAC MP4 transcoded by the server at the given total bitrate.
    func transcodedDownloadURL(itemId: String, mediaSourceId: String?, mbit: Double, audioStreamIndex: Int? = nil) -> URL {
        url("Videos/\(itemId)/stream.mp4", downloadTranscodeQuery(mediaSourceId: mediaSourceId, mbit: mbit,
                                                                 audioStreamIndex: audioStreamIndex, playSessionId: nil))
    }

    /// The HLS playlist of a transcoded download: 24-second fragmented-MP4 segments that can be fetched
    /// one by one, so an interrupted download continues instead of starting over. Video is always
    /// re-encoded (no stream copy), so segments cut at exactly the same points after a restart.
    func hlsDownloadPlaylistURL(itemId: String, mediaSourceId: String?, mbit: Double, audioStreamIndex: Int?,
                                playSessionId: String) -> URL {
        var query = downloadTranscodeQuery(mediaSourceId: mediaSourceId, mbit: mbit,
                                           audioStreamIndex: audioStreamIndex, playSessionId: playSessionId)
        query["segmentContainer"] = "mp4"
        query["segmentLength"] = String(Self.downloadSegmentSeconds)
        query["allowVideoStreamCopy"] = "false"
        query["breakOnNonKeyFrames"] = "false"
        return url("Videos/\(itemId)/main.m3u8", query)
    }

    static let downloadSegmentSeconds = 24
}
