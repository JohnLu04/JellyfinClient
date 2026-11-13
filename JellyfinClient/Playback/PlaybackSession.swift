import Foundation

enum PlayMethod: String {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

/// Everything needed to play one item from the server: the stream URL the server chose for this
/// player, bitrate limit and track selection, plus the stream list for the track menus.
struct PlaybackSession {
    let api: JellyfinAPI
    let item: BaseItem
    let source: MediaSourceInfo
    let playSessionId: String?
    let playMethod: PlayMethod
    let url: URL
    let maxMbit: Double
    let player: PlayerKind
    var selection: TrackSelection

    private var streams: [MediaStream] {
        source.mediaStreams ?? item.primaryMediaSource?.mediaStreams ?? []
    }
    var audioStreams: [MediaStream] { streams.filter { $0.type == "Audio" } }
    var subtitleStreams: [MediaStream] { streams.filter { $0.type == "Subtitle" } }

    func subtitleStream(_ index: Int?) -> MediaStream? {
        index.flatMap { idx in subtitleStreams.first { $0.index == idx } }
    }

    /// True when the server burns the selected subtitle into the video (image subtitles while transcoding).
    var hasBurnedInSubtitle: Bool {
        guard playMethod != .directPlay, let stream = subtitleStream(selection.subtitleIndex) else { return false }
        return !stream.isTextSubtitle
    }
}

/// Something that plays a session and can be asked for its state when reporting progress.
@MainActor
protocol PlaybackEngine: AnyObject {
    var currentSeconds: Double { get }
    var isPausedNow: Bool { get }
    func teardown()
}

enum PlaybackResolver {
    /// `POST /Items/{id}/PlaybackInfo` with the player's device profile, bitrate limit and track choice.
    /// - Server returns a `TranscodingUrl` → HLS stream (remux or transcode).
    /// - Otherwise the file is directly playable → static stream of the original file.
    static func resolve(item: BaseItem, api: JellyfinAPI, maxMbit: Double,
                        selection: TrackSelection, player: PlayerKind) async throws -> PlaybackSession {
        let info = try await api.playbackInfo(itemId: item.id, maxBitrate: Bitrate.bps(forMbit: maxMbit), player: player,
                                              mediaSourceId: item.primaryMediaSource?.id, selection: selection)
        if let code = info.errorCode { throw APIError.playback(code: code) }
        guard let source = info.mediaSources?.first else { throw APIError.noPlayableSource }

        let url: URL
        let method: PlayMethod
        if let transcodingPath = source.transcodingUrl, let resolved = api.absoluteURL(serverRelative: transcodingPath) {
            url = adjustTranscodingURL(api.withToken(resolved), source: source, maxMbit: maxMbit)
            method = transcodingPath.localizedCaseInsensitiveContains("videocodec=copy") ? .directStream : .transcode
        } else if source.supportsDirectPlay == true || source.supportsDirectStream == true {
            url = api.directStreamURL(itemId: item.id, mediaSourceId: source.id,
                                      container: source.container, playSessionId: info.playSessionId)
            method = .directPlay
        } else {
            throw APIError.noPlayableSource
        }

        #if DEBUG
        print("[Playback] \(player.rawValue) \(method.rawValue) → \(url.absoluteString.replacingOccurrences(of: api.accessToken ?? "-", with: "<token>"))")
        #endif

        return PlaybackSession(api: api, item: item, source: source, playSessionId: info.playSessionId,
                               playMethod: method, url: url, maxMbit: maxMbit, player: player, selection: selection)
    }

    /// When we're limiting bitrate below the source's, also cap the resolution so low bitrates stay watchable.
    private static func adjustTranscodingURL(_ url: URL, source: MediaSourceInfo, maxMbit: Double) -> URL {
        guard maxMbit > 0, (source.bitrate ?? .max) > Bitrate.bps(forMbit: maxMbit),
              let width = Bitrate.maxWidth(forMbit: maxMbit),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        guard !items.contains(where: { $0.name.lowercased() == "maxwidth" }) else { return url }
        items.append(URLQueryItem(name: "maxWidth", value: String(width)))
        comps.queryItems = items
        return comps.url ?? url
    }
}
