import Foundation
import os

let abrLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JellyfinClient", category: "ABR")

/// "Automatic" streaming quality without reloading the video.
///
/// The server transcodes the title into a ladder of qualities (Jellyfin HLS, one `main.m3u8` per rung,
/// all cut at the same 6-second points with the same timestamps). A small local server hands the player
/// one continuous stream:
/// - **mpv** gets a single playlist; for every segment it asks for, `AdaptiveStream` decides which rung
///   to take it from. Segments of different rungs join seamlessly, so the picture just gets sharper or
///   softer – no reload, no pause.
/// - **Apple's player** gets a master playlist with all rungs and switches with its own adaptive logic.
///
/// The decision (mpv) uses the measured download rate of recent segments (fast and slow average, the
/// lower one, with a safety margin) and how many seconds the player has buffered: with the buffer
/// running low it steps down right away, long before it is empty; it only steps up, one rung at a time,
/// when the buffer is comfortable and the rate has confirmed it twice.
actor AdaptiveStream {
    struct Rung: Sendable {
        let index: Int
        let totalBps: Int
        let maxWidth: Int?
        let playSessionId: String
        let playlistURL: URL
        var mbit: Double { Double(totalBps) / 1_000_000 }
    }

    /// What the stats panel shows.
    struct Status: Sendable {
        var rungMbit: Double = 0
        var estimateBps: Double?
        var bufferSeconds: Double = 0
        var switches = 0
    }

    private struct Segment { let url: URL; let duration: Double }
    private struct MediaPlaylist { let initURL: URL?; let segments: [Segment] }

    nonisolated let rungs: [Rung]
    nonisolated let forMPV: Bool
    nonisolated private let statusLock = OSAllocatedUnfairLock(initialState: Status())
    nonisolated var status: Status { statusLock.withLock { $0 } }

    private let api: JellyfinAPI
    private let fetcher = SegmentFetcher()
    private var server: LocalHTTPServer?
    private var playlists: [Int: MediaPlaylist] = [:]
    private var initData: Data?

    private var current: Int
    private var fastEstimate: Double?
    private var slowEstimate: Double?
    private var buffer: Double = 0
    private var bufferHealthy = false
    private var lastSegment = -1
    private var upVotes = 0
    /// How long the last segment of the current rung took to fetch, relative to how long it plays
    /// (0.4 = it arrived in 40 % of its playing time). Measured directly, so it isn't fooled by small
    /// segments that look slow over Wi-Fi. nil right after a switch.
    private var fetchRatio: Double?
    /// Set when a step up was a try beyond the measured rate; if it has to come back down quickly,
    /// further tries pause for a while.
    private var probeSegment: Int?
    private var probeBlockedUntil = Date.distantPast
    /// The first segment after a switch or seek includes the server starting a transcode; its total time
    /// says nothing about whether the rung can keep up.
    private var freshStart = true
    private var usedRungs: Set<Int> = []
    private var rungToStop: Int?

    private static let estimateKey = "abr.lastEstimateBps"

    private init(api: JellyfinAPI, rungs: [Rung], forMPV: Bool, initial: Int) {
        self.api = api
        self.rungs = rungs
        self.forMPV = forMPV
        self.current = initial
    }

    // MARK: - Setup

    /// Builds the ladder from the server's transcoding URL and starts the local server.
    /// Returns the stream and the URL the player should open.
    static func start(api: JellyfinAPI, template: URL, source: MediaSourceInfo, forMPV: Bool) async throws -> (AdaptiveStream, URL) {
        let rungs = makeRungs(template: template, source: source, forMPV: forMPV)
        guard !rungs.isEmpty else { throw APIError.noPlayableSource }
        let saved = UserDefaults.standard.double(forKey: estimateKey)
        // Start modestly (quick start, no stall on a slower network than last time) and climb from there.
        let startBps = min(saved > 0 ? saved * 0.5 : 2_500_000, 4_000_000)
        let initial = rungs.lastIndex { Double($0.totalBps) <= startBps } ?? 0
        let stream = AdaptiveStream(api: api, rungs: rungs, forMPV: forMPV, initial: initial)
        let port = try await stream.startServer()
        if forMPV { try await stream.loadPlaylist(initial) }
        let url = URL(string: "http://127.0.0.1:\(port)/\(forMPV ? "media" : "master").m3u8")!
        abrLog.notice("Adaptive stream: \(rungs.map { $0.mbit.formatted() }.joined(separator: " / "), privacy: .public) Mbit/s, starting at \(rungs[initial].mbit) Mbit/s")
        stream.publish(rung: rungs[initial].mbit)
        return (stream, url)
    }

    /// Ladder of total bitrates (video + audio), never above the original file's bitrate.
    nonisolated private static func makeRungs(template: URL, source: MediaSourceInfo, forMPV: Bool) -> [Rung] {
        let ladder: [Double] = [0.7, 1.5, 2.5, 4, 6, 8, 12, 20, 40]
        let sourceMbit = source.bitrate.map { Double($0) / 1_000_000 } ?? 20
        var totals = ladder.filter { $0 <= sourceMbit * 1.05 }
        if totals.isEmpty { totals = [ladder[0]] }
        let base = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
        return totals.enumerated().compactMap { index, total in
            let audioBps = 192_000
            let videoBps = max(Int(total * 1_000_000) - audioBps, 300_000)
            let width = Bitrate.maxWidth(forMbit: total)
            let id = "\(base)r\(index)"
            guard let url = rungURL(template: template, videoBps: videoBps, audioBps: audioBps, maxWidth: width,
                                    playSessionId: id, forMPV: forMPV) else { return nil }
            return Rung(index: index, totalBps: videoBps + audioBps, maxWidth: width, playSessionId: id, playlistURL: url)
        }
    }

    /// The server's own transcoding URL with this rung's bitrate and size. Always re-encoded H.264 (no
    /// stream copy), so all rungs are cut at the same points; mpv gets self-contained TS segments.
    nonisolated private static func rungURL(template: URL, videoBps: Int, audioBps: Int, maxWidth: Int?,
                                            playSessionId: String, forMPV: Bool) -> URL? {
        guard var components = URLComponents(url: template, resolvingAgainstBaseURL: false) else { return nil }
        if components.path.lowercased().hasSuffix("master.m3u8") {
            components.path = String(components.path.dropLast("master.m3u8".count)) + "main.m3u8"
        }
        var items = components.queryItems ?? []
        func set(_ name: String, _ value: String?) {
            items.removeAll { $0.name.lowercased() == name.lowercased() }
            if let value { items.append(URLQueryItem(name: name, value: value)) }
        }
        set("VideoCodec", "h264")
        set("VideoBitrate", String(videoBps))
        set("AudioBitrate", String(audioBps))
        set("MaxWidth", maxWidth.map(String.init))
        set("MaxHeight", nil)
        set("PlaySessionId", playSessionId)
        set("AllowVideoStreamCopy", "false")
        set("BreakOnNonKeyFrames", "false")
        set("SegmentLength", "6")
        set("TranscodeReasons", nil)
        if forMPV { set("SegmentContainer", "ts") }
        components.queryItems = items
        return components.url
    }

    private func startServer() async throws -> UInt16 {
        let server = LocalHTTPServer { [weak self] path in
            guard let self else { return .notFound() }
            return await self.handle(path)
        }
        self.server = server
        return try await server.start()
    }

    // MARK: - Player input

    /// Seconds the player has buffered ahead (mpv: `demuxer-cache-duration`), updated every second.
    nonisolated func updateBuffer(_ seconds: Double) {
        Task { await setBuffer(seconds) }
    }

    private func setBuffer(_ seconds: Double) {
        buffer = seconds
        if seconds >= thresholds.low + 3 { bufferHealthy = true }
        statusLock.withLock { $0.bufferSeconds = seconds }
    }

    /// Ends the stream: stops the local server and the server's transcodes for every rung used.
    nonisolated func stop() {
        Task { await shutdown() }
    }

    private func shutdown() async {
        server?.stop()
        server = nil
        if let estimate = estimate { UserDefaults.standard.set(estimate, forKey: Self.estimateKey) }
        let ids = forMPV ? usedRungs.map { rungs[$0].playSessionId } : rungs.map(\.playSessionId)
        for id in ids { try? await api.stopTranscoding(playSessionId: id) }
    }

    // MARK: - Local server

    deinit { abrLog.notice("Adaptive stream released") }

    private func handle(_ path: String) async -> LocalHTTPServer.Response {
        abrLog.debug("Request \(path, privacy: .public)")
        let route = path.split(separator: "?").first.map(String.init) ?? path
        if route == "/master.m3u8" { return masterPlaylist() }
        if route == "/media.m3u8" { return mediaPlaylist() }
        if route.hasPrefix("/init.") { return await initSegment() }
        if route.hasPrefix("/seg/"), let n = Int(route.dropFirst(5).split(separator: ".").first ?? "") {
            return await segment(n)
        }
        return .notFound()
    }

    /// Apple's player: every rung as a variant; it picks and switches by itself.
    private func masterPlaylist() -> LocalHTTPServer.Response {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for rung in rungs {
            var attributes = "BANDWIDTH=\(Int(Double(rung.totalBps) * 1.1)),AVERAGE-BANDWIDTH=\(rung.totalBps),CODECS=\"avc1.640028,mp4a.40.2\""
            if let width = rung.maxWidth { attributes += ",RESOLUTION=\(width)x\(width * 9 / 16)" }
            lines.append("#EXT-X-STREAM-INF:\(attributes)")
            lines.append(rung.playlistURL.absoluteString)
        }
        return LocalHTTPServer.Response(contentType: "application/vnd.apple.mpegurl", body: Data(lines.joined(separator: "\n").utf8))
    }

    /// mpv: one playlist with the segment times of the ladder; each segment is fetched from the rung
    /// chosen when it's requested.
    private func mediaPlaylist() -> LocalHTTPServer.Response {
        guard let template = playlists[current] ?? playlists.values.first else { return .notFound() }
        let target = Int((template.segments.map(\.duration).max() ?? 6).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:\(template.initURL == nil ? 3 : 7)", "#EXT-X-TARGETDURATION:\(target)",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
        if let initURL = template.initURL { lines.append("#EXT-X-MAP:URI=\"init.\(initURL.pathExtension.isEmpty ? "mp4" : initURL.pathExtension)\"") }
        for (index, segment) in template.segments.enumerated() {
            let ext = segment.url.pathExtension.isEmpty ? "ts" : segment.url.pathExtension
            lines.append("#EXTINF:\(String(format: "%.6f", segment.duration)),")
            lines.append("seg/\(index).\(ext)")
        }
        lines.append("#EXT-X-ENDLIST")
        return LocalHTTPServer.Response(contentType: "application/vnd.apple.mpegurl", body: Data(lines.joined(separator: "\n").utf8))
    }

    private func initSegment() async -> LocalHTTPServer.Response {
        if let initData { return LocalHTTPServer.Response(contentType: "video/mp4", body: initData) }
        guard let url = playlists[current]?.initURL ?? playlists.values.first?.initURL,
              let result = try? await fetcher.fetch(request(url)) else { return LocalHTTPServer.Response(status: 502) }
        initData = result.data
        return LocalHTTPServer.Response(contentType: "video/mp4", body: result.data)
    }

    private func segment(_ n: Int) async -> LocalHTTPServer.Response {
        if n != lastSegment + 1 {
            // A seek (or the start): the buffer starts from zero again, which is no reason to step down.
            bufferHealthy = false
            freshStart = true
            upVotes = 0
        }
        lastSegment = n
        var rung = decide()
        for attempt in 0..<4 {
            do {
                try await loadPlaylist(rung)
                guard let playlist = playlists[rung], playlist.segments.indices.contains(n) else { return .notFound() }
                let duration = playlist.segments[n].duration
                let result = try await fetchWithDeadline(playlist.segments[n].url, rung: rung, segmentDuration: duration)
                record(result, segmentDuration: duration)
                if let old = rungToStop, old != rung {
                    // The new rung delivers: end the old rung's transcode on the server.
                    rungToStop = nil
                    let id = rungs[old].playSessionId
                    Task { try? await api.stopTranscoding(playSessionId: id) }
                }
                usedRungs.insert(rung)
                let ext = playlist.segments[n].url.pathExtension.lowercased()
                return LocalHTTPServer.Response(contentType: ext == "ts" ? "video/mp2t" : "video/mp4", body: result.data)
            } catch SegmentTooSlow.abandoned {
                // Would have eaten too much of the buffer: take it two rungs lower right away.
                switchTo(max(rung - 2, 0), reason: "segment too slow, buffer \(Int(buffer)) s")
                fastEstimate = min(fastEstimate ?? .infinity, Double(rungs[current].totalBps) / 0.75)
                rung = current
            } catch {
                abrLog.error("Segment \(n) from \(self.rungs[rung].mbit) Mbit/s failed (attempt \(attempt + 1)): \(error.localizedDescription, privacy: .public)")
                if rung > 0 { switchTo(rung - 1, reason: "segment failed") ; rung = current }
                try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            }
        }
        return LocalHTTPServer.Response(status: 502)
    }

    private enum SegmentTooSlow: Error { case abandoned }

    /// Fetches a segment, but gives up (on any rung but the lowest) once it has taken longer than the
    /// buffer can cover comfortably – half of what's buffered, at least one and a half segments.
    private func fetchWithDeadline(_ url: URL, rung: Int, segmentDuration: Double) async throws -> SegmentFetcher.Result {
        let request = request(url)
        let fetcher = self.fetcher
        guard rung > 0, bufferHealthy else { return try await fetcher.fetch(request) }
        let deadline = max(segmentDuration * 1.5, buffer * 0.5)
        return try await withThrowingTaskGroup(of: SegmentFetcher.Result?.self) { group in
            group.addTask { try await fetcher.fetch(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else { throw SegmentTooSlow.abandoned }
            return result
        }
    }

    // MARK: - Decision

    private var estimate: Double? {
        switch (fastEstimate, slowEstimate) {
        case let (fast?, slow?): min(fast, slow)
        case let (fast?, nil): fast
        default: nil
        }
    }

    /// Buffer levels scale with the buffer setting (60 s by default).
    private var thresholds: (up: Double, low: Double, panic: Double) {
        let target = PlaybackBuffer.seconds
        return (min(20, target * 0.6), min(12, target * 0.35), min(5, target * 0.15))
    }

    /// Picks the rung for the next segment.
    ///
    /// - Rate: with little buffer the lower of the fast and slow average with a 30 % margin; with more
    ///   buffer the fast average with 15 % margin, and none once 30 s are buffered.
    /// - Keeping up: if the current rung's segments arrive in well under their playing time and 30 s are
    ///   buffered, the rung stays even if the rate looks lower (small segments are measured too slow).
    /// - Trying higher: with the buffer comfortably full, it steps one rung up when the current rung's
    ///   fetch time predicts the next one still arrives in under 85 % of its playing time.
    /// - Buffer: below 12 s one rung down, below 5 s straight to the lowest (only after it was full once).
    private func decide() -> Int {
        var target = current
        let comfortable = min(45, PlaybackBuffer.seconds * 0.8)
        let rate = buffer < 15 ? estimate : (fastEstimate ?? estimate)
        if let rate {
            let margin = buffer < 15 ? 0.7 : (buffer < 30 ? 0.85 : 1.0)
            var affordable = rungs.lastIndex { Double($0.totalBps) <= rate * margin } ?? 0
            var probe = false
            if affordable < current, buffer >= 30, (fetchRatio ?? 0) <= 0.85 {
                affordable = current                                  // keeping up fine: stay
            }
            if affordable == current, bufferHealthy, buffer >= comfortable, current + 1 < rungs.count,
               Date.now >= probeBlockedUntil, let ratio = fetchRatio,
               ratio * Double(rungs[current + 1].totalBps) / Double(rungs[current].totalBps) <= 0.85 {
                affordable = current + 1                              // room to try the next rung
                probe = true
            }
            if affordable < current {
                if let start = probeSegment, lastSegment - start <= 5 {
                    probeBlockedUntil = .now.addingTimeInterval(120)  // the try didn't hold
                }
                probeSegment = nil
                target = affordable                                   // down right away
                upVotes = 0
            } else if affordable > current, bufferHealthy, buffer >= thresholds.up {
                upVotes += 1
                if upVotes >= 2 {                                     // up one rung, once confirmed
                    target = current + 1
                    upVotes = 0
                    probeSegment = probe ? lastSegment : nil
                }
            } else {
                upVotes = 0
            }
        }
        if bufferHealthy {
            if buffer < thresholds.panic {
                target = 0
            } else if buffer < thresholds.low {
                target = min(target, max(current - 1, 0))
            }
        }
        if target != current {
            switchTo(target, reason: String(format: "rate %.1f Mbit/s, fetch %.0f %% of play time, buffer %.0f s",
                                            (rate ?? 0) / 1_000_000, (fetchRatio ?? 0) * 100, buffer))
        }
        return current
    }

    private func switchTo(_ rung: Int, reason: String) {
        guard rung != current, rungs.indices.contains(rung) else { return }
        abrLog.notice("Quality \(self.rungs[self.current].mbit) → \(self.rungs[rung].mbit) Mbit/s (\(reason, privacy: .public))")
        rungToStop = current
        current = rung
        fetchRatio = nil
        freshStart = true
        upVotes = 0
        statusLock.withLock { $0.switches += 1 }
        publish(rung: rungs[rung].mbit)
    }

    /// Network rate from first to last byte (so the server's transcode start doesn't count); if the
    /// whole fetch took longer than the segment plays, the rung can't keep up – that counts too.
    private func record(_ result: SegmentFetcher.Result, segmentDuration: Double) {
        let bits = Double(result.data.count * 8)
        guard result.data.count > 64_000 else { freshStart = false; return }
        var sample = bits / max(result.transferSeconds, 0.05)
        if !freshStart {
            fetchRatio = result.totalSeconds / max(segmentDuration, 0.5)
            if result.totalSeconds > segmentDuration { sample = min(sample, bits / result.totalSeconds) }
        }
        freshStart = false
        // A sharp drop counts right away; otherwise smooth it.
        if let fast = fastEstimate, sample < fast * 0.5 {
            fastEstimate = sample
        } else {
            fastEstimate = fastEstimate.map { $0 * 0.5 + sample * 0.5 } ?? sample
        }
        slowEstimate = slowEstimate.map { $0 * 0.85 + sample * 0.15 } ?? sample
        let shown = fastEstimate ?? self.estimate
        statusLock.withLock { $0.estimateBps = shown }
    }

    nonisolated private func publish(rung mbit: Double) {
        statusLock.withLock { $0.rungMbit = mbit }
    }

    // MARK: - Fetching

    private func loadPlaylist(_ rung: Int) async throws {
        guard playlists[rung] == nil else { return }
        let result = try await fetcher.fetch(request(rungs[rung].playlistURL))
        guard let text = String(data: result.data, encoding: .utf8),
              let playlist = Self.parse(text, base: rungs[rung].playlistURL) else { throw APIError.noPlayableSource }
        playlists[rung] = playlist
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(api.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        return request
    }

    /// Jellyfin's VOD playlist: `#EXTINF` durations, segment URIs, optional `#EXT-X-MAP`.
    nonisolated private static func parse(_ text: String, base: URL) -> MediaPlaylist? {
        var initURL: URL?
        var segments: [Segment] = []
        var pendingDuration: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                pendingDuration = Double(line.dropFirst(8).split(separator: ",").first ?? "")
            } else if line.hasPrefix("#EXT-X-MAP:"), let start = line.range(of: "URI=\"")?.upperBound,
                      let end = line[start...].firstIndex(of: "\"") {
                initURL = URL(string: String(line[start..<end]), relativeTo: base)?.absoluteURL
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: base)?.absoluteURL {
                segments.append(Segment(url: url, duration: pendingDuration ?? 6))
                pendingDuration = nil
            }
        }
        return segments.isEmpty ? nil : MediaPlaylist(initURL: initURL, segments: segments)
    }
}

/// Downloads segments and reports how long the transfer itself took (first to last byte).
final class SegmentFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Result {
        let data: Data
        let transferSeconds: Double
        let totalSeconds: Double
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var metrics: URLSessionTaskMetrics?
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            self.metrics = metrics
        }
    }

    func fetch(_ request: URLRequest) async throws -> Result {
        let collector = MetricsCollector()
        let started = Date.now
        let (data, response) = try await session.data(for: request, delegate: collector)
        let total = Date.now.timeIntervalSince(started)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        var transfer = total
        if let transaction = collector.metrics?.transactionMetrics.last,
           let first = transaction.responseStartDate, let last = transaction.responseEndDate {
            transfer = max(last.timeIntervalSince(first), 0.001)
        }
        return Result(data: data, transferSeconds: transfer, totalSeconds: total)
    }
}
