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
            return "Server error \(status)" + (detail.map { ": \($0)" } ?? "")
        case let .playback(code):
            switch code {
            case "NotAllowed": return String(localized: "Playback isn't allowed for this user.")
            case "NoCompatibleStream": return String(localized: "The server found no stream this iPhone can play.")
            case "RateLimitExceeded": return String(localized: "The server's streaming limit was reached.")
            default: return "Playback error: \(code)"
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

    static let listFields = "PrimaryImageAspectRatio,Overview,MediaSources"

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

    func item(id: String) async throws -> BaseItem {
        try await get("Items/\(id)", ["userId": userId])
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Shows/\(seriesId)/Seasons", ["userId": userId])
        return result.items
    }

    func episodes(seriesId: String, seasonId: String) async throws -> [BaseItem] {
        let result: ItemsResult = try await get("Shows/\(seriesId)/Episodes", [
            "userId": userId, "seasonId": seasonId, "fields": Self.listFields,
        ])
        return result.items
    }

    // MARK: - Images

    func imageURL(itemId: String, type: String, tag: String?, maxWidth: Int) -> URL {
        url("Items/\(itemId)/Images/\(type)", ["maxWidth": String(maxWidth), "quality": "90", "tag": tag])
    }

    func posterURL(for item: BaseItem, maxWidth: Int = 300) -> URL? {
        item.imageTag("Primary").map { imageURL(itemId: item.id, type: "Primary", tag: $0, maxWidth: maxWidth) }
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

    /// A progressive H.264/AAC MP4 transcoded by the server at the given total bitrate.
    func transcodedDownloadURL(itemId: String, mediaSourceId: String?, mbit: Double) -> URL {
        let total = Bitrate.bps(forMbit: mbit)
        let audio = total >= 1_500_000 ? 192_000 : 128_000
        let video = max(total - audio, 250_000)
        var query: [String: String?] = [
            "mediaSourceId": mediaSourceId,
            "deviceId": Self.deviceId,
            "playSessionId": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "api_key": accessToken,
            "videoCodec": "h264",
            "audioCodec": "aac",
            "videoBitRate": String(video),
            "audioBitRate": String(audio),
            "maxAudioChannels": "2",
        ]
        if let width = Bitrate.maxWidth(forMbit: mbit) { query["maxWidth"] = String(width) }
        return url("Videos/\(itemId)/stream.mp4", query)
    }
}
