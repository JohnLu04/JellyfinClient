import Foundation
import Observation
import UIKit
import UserNotifications
import os

let downloadLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JellyfinClient", category: "Downloads")

/// Downloads movies and episodes into Documents/Downloads, built like Streamyfin's native downloader:
///
/// - Every transfer runs in a **background URLSession**, carried out by iOS' download service, not the
///   app. Leaving the app, locking the screen or iOS ending the app doesn't stop it; iOS relaunches the
///   app in the background to file finished transfers.
/// - Task descriptions (keys, see `DownloadPart`) and the index on disk survive a relaunch.
/// - Downloads run **one at a time** from a persisted queue.
///
/// Interruptions (closing the app, losing the connection) don't start a download over:
/// - **Originals** continue from URLSession's resume data (Jellyfin serves them with byte ranges).
/// - **Transcodes** are fetched as 24-second HLS segments (two at a time) appended to one fragmented MP4, so only the
///   segment in flight is lost; Jellyfin can't resume a progressive transcode.
/// - Extra audio tracks and subtitles follow the video as separate files.
///
/// iOS treats transfers that a background session starts while the app is in the background as
/// "discretionary" and postpones them, often until the app is opened again. A transcode starts a new
/// transfer for every segment, so while the keep-alive (see `DownloadKeepAlive`) keeps the app running
/// in the background, new transfers go through an ordinary in-app session instead and start at once.
/// When iOS ends the keep-alive, they are handed back to the background session.
@Observable @MainActor
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    nonisolated static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "JellyfinClient") + ".downloads"
    private static let maxConcurrent = 1
    private static let maxRetries = 10
    private static let maxConnectivityRetries = 120
    /// Server errors on a subtitle (e.g. it can't be extracted): about a minute of tries, then it's skipped.
    private static let maxExtraServerRetries = 6
    /// Segments requested at once. More would make Jellyfin restart the transcode: it does once a
    /// request is more than 24 s / segment length ahead of what it is encoding.
    private static let segmentPipeline = 2

    private(set) var records: [DownloadRecord] = []
    /// Current transfer speed in bytes per second, by item id.
    private(set) var speeds: [String: Double] = [:]
    /// Bumped when a series poster was saved, so the download folders show it.
    private(set) var posterRevision = 0

    /// Handed over by the app delegate when iOS wakes the app for this session; called once all
    /// pending events are delivered.
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    /// What the keep-alive was last told, for which download.
    @ObservationIgnored private var keepAliveReported: (id: String, units: Int64) = ("", 0)

    @ObservationIgnored private var session: URLSession!
    /// For transfers started while the app is kept running in the background (see the type's notes).
    @ObservationIgnored private var inAppSession: URLSession!
    /// Transfers running in `inAppSession`; they end with the app, so they are handed over in time.
    @ObservationIgnored private var inAppTasks: Set<ObjectIdentifier> = []
    /// Transfers cancelled on purpose (handed over, or a duplicate); their end is not a failure.
    @ObservationIgnored private var abandonedTasks: Set<ObjectIdentifier> = []
    /// iOS ended the keep-alive: no new in-app transfers until the app is back in the foreground.
    @ObservationIgnored private var inAppBlocked = false
    /// Paused transfers whose resume data is still being written; they restart only once it's there.
    @ObservationIgnored private var pendingResumeData: Set<String> = []
    /// Running transfers by key (a transcode has up to `segmentPipeline` segments in flight).
    @ObservationIgnored private var liveTasks: [String: URLSessionTask] = [:]
    /// Bytes received so far by segments in flight, for the progress bar.
    @ObservationIgnored private var inflightBytes: [String: (written: Int64, expected: Int64)] = [:]
    @ObservationIgnored private var playlistFetches: Set<String> = []
    /// Subtitles being fetched ahead (keys), and the downloads that got that chance in this run.
    @ObservationIgnored private var subtitleFetches: Set<String> = []
    @ObservationIgnored private var subtitlePrefetchStarted: Set<String> = []
    @ObservationIgnored private var isReconnected = false
    /// The index exists but can't be read yet (woken while the iPhone is locked and the file is still
    /// under complete protection). Nothing is saved or deleted until it can be read.
    @ObservationIgnored private var indexUnavailable = false
    /// Transfers finished while the index was unreadable; filed once it can be read.
    @ObservationIgnored private var pendingCompletions: [(key: String, fileName: String, size: Int64)] = []
    @ObservationIgnored private var eventsDelivered = false
    @ObservationIgnored private var speedSamples: [String: (time: Date, bytes: Int64)] = [:]
    @ObservationIgnored private var attemptStartBytes: [String: Int64] = [:]
    @ObservationIgnored private var lastIndexSave = Date.distantPast

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    nonisolated private static func resumeDataURL(for key: String) -> URL {
        directory.appendingPathComponent(".\(key).resume")
    }

    /// The segmented video (or audio track) while it grows, and its segment list.
    private static func hlsOutputURL(for id: String, _ target: HLSTarget = .video) -> URL {
        directory.appendingPathComponent(".\(id)\(suffix(target)).hls.mp4")
    }
    private static func hlsListURL(for id: String, _ target: HLSTarget = .video) -> URL {
        directory.appendingPathComponent(".\(id)\(suffix(target)).hls.json")
    }
    private static func suffix(_ target: HLSTarget) -> String {
        if case .extra(let n) = target { return ".x\(n)" }
        return ""
    }

    private func hlsProgress(of record: DownloadRecord, _ target: HLSTarget) -> HLSProgress? {
        switch target {
        case .video: return record.hls
        case .extra(let n): return record.extras?.indices.contains(n) == true ? record.extras?[n].hls : nil
        }
    }

    private func setHLSProgress(_ value: HLSProgress?, at index: Int, _ target: HLSTarget) {
        switch target {
        case .video: records[index].hls = value
        case .extra(let n): if records[index].extras?.indices.contains(n) == true { records[index].extras?[n].hls = value }
        }
    }

    private func hlsIsComplete(_ record: DownloadRecord, _ target: HLSTarget) -> Bool {
        guard let hls = hlsProgress(of: record, target) else { return false }
        return hls.hasInitSegment && hls.nextSegment >= hls.segmentCount
    }

    /// Transcoded downloads fetch extra audio tracks as segments too; subtitles are one small file.
    private func extraUsesHLS(_ record: DownloadRecord, _ n: Int) -> Bool {
        record.mbit != nil && record.extras?.indices.contains(n) == true && record.extras?[n].kind == .audio
    }

    private func label(_ target: HLSTarget, _ record: DownloadRecord) -> String {
        guard case .extra(let n) = target, let extra = record.extras?[n] else { return "" }
        return "audio track \(extra.streamIndex) (\(extra.title)): "
    }

    private func liveKeys(of id: String) -> [String] {
        liveTasks.keys.filter { DownloadPart.parse($0).id == id }
    }

    /// A segment that arrived before the one in front of it waits on disk as "<key>.<ext>".
    private func readySegmentFile(id: String, _ part: DownloadPart) -> URL? {
        let prefix = part.key(for: id) + "."
        return ((try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
            .first { $0.hasPrefix(prefix) }
            .map { Self.directory.appendingPathComponent($0) }
    }

    private override init() {
        super.init()
        Self.prepareDirectory()
        loadIndex()

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true          // relaunch the app when a transfer finishes
        config.isDiscretionary = false                  // start now, not when iOS finds it convenient
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForRequest = 300          // transcoding can pause between chunks
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Downloads"
        // Recreating the session with the same identifier reattaches to transfers that kept running
        // while the app was gone; their pending events are delivered right after this.
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)

        let inAppConfig = URLSessionConfiguration.default
        inAppConfig.timeoutIntervalForRequest = 300
        inAppConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        inAppConfig.urlCache = nil
        inAppSession = URLSession(configuration: inAppConfig, delegate: self, delegateQueue: queue)

        session.getAllTasks { tasks in
            let downloads = tasks.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor in self.reconnect(downloads) }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(protectedDataAvailable),
            name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    }

    /// Sideloading tools often sign with the provisioning profile's default data protection
    /// ("complete"), which locks the app's files whenever the iPhone is locked. The download folder
    /// and its files use "until first unlock" instead (iOS' normal default), so finished downloads and
    /// the index can be written while locked. Existing files can only be changed while unlocked.
    nonisolated private static func prepareDirectory() {
        let fileManager = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        try? fileManager.setAttributes(protection, ofItemAtPath: directory.path)
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? fileManager.setAttributes(protection, ofItemAtPath: directory.appendingPathComponent(name).path)
        }
    }

    // MARK: - Queries

    func record(for id: String) -> DownloadRecord? { records.first { $0.id == id } }

    func fileURL(for record: DownloadRecord) -> URL? {
        record.fileName.map { Self.directory.appendingPathComponent($0) }
    }

    func posterURL(for record: DownloadRecord) -> URL? {
        record.posterFileName.map { Self.directory.appendingPathComponent($0) }
    }

    /// The series poster for a series folder in the download list (saved with its first episode).
    func seriesPosterURL(seriesId: String) -> URL? {
        let url = Self.seriesPosterURL(seriesId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func seriesPosterURL(_ seriesId: String) -> URL {
        directory.appendingPathComponent("series-\(seriesId)-poster.jpg")
    }

    /// Saves the series poster once, for the series' folder.
    private func saveSeriesPoster(for item: BaseItem, api: JellyfinAPI) async {
        guard item.type == "Episode", let seriesId = item.seriesId else { return }
        let destination = Self.seriesPosterURL(seriesId)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let url = api.imageURL(itemId: seriesId, type: "Primary", tag: item.seriesPrimaryImageTag, maxWidth: 300)
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { return }
        try? data.write(to: destination, options: .atomic)
        posterRevision += 1
    }

    /// Copies series and season of an episode into its download, for the folders in the download list.
    private func setEpisodeInfo(at index: Int, from item: BaseItem) {
        guard item.type == "Episode" else { return }
        records[index].seriesId = item.seriesId
        records[index].seriesName = item.seriesName ?? records[index].episodeInfo?.series
        records[index].seasonId = item.seasonId
        records[index].seasonName = item.seasonName
        records[index].seasonNumber = item.parentIndexNumber
        records[index].episodeNumber = item.indexNumber
    }

    var totalBytes: Int64 {
        records.filter { $0.state == .completed }.reduce(0) { $0 + $1.bytesWritten }
    }

    var hasActiveDownloads: Bool { records.contains { $0.isActive } }

    /// Extra audio tracks and subtitles of a finished download, for offline playback.
    func extraFiles(for record: DownloadRecord) -> [(extra: DownloadExtra, url: URL)] {
        record.finishedExtras.compactMap { extra in
            extra.fileName.map { (extra, Self.directory.appendingPathComponent($0)) }
        }
    }

    // MARK: - Actions

    /// Adds the item to the download queue.
    /// - Parameter mbit: transcode to this bitrate, or `nil` for the original file.
    func start(item: BaseItem, api: JellyfinAPI, mbit: Double?, tracks: DownloadTrackOptions = .stored) {
        delete(id: item.id)
        subtitlePrefetchStarted.remove(item.id)

        let subtitle = [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        let source = item.primaryMediaSource
        let expected = mbit.flatMap { Bitrate.estimatedBytes(mbit: $0, runTimeTicks: item.runTimeTicks) }
            ?? source?.size

        // A transcoded file carries one audio track (the default one); the others become extra files.
        // An original file has all embedded tracks already; only external subtitles are missing.
        var extras: [DownloadExtra] = []
        let mainAudio = mbit == nil ? nil : TrackSelection.defaults(for: source).audioIndex
        if mbit != nil, tracks.allAudioTracks {
            for stream in source?.audioStreams ?? [] where stream.index != mainAudio {
                extras.append(DownloadExtra(kind: .audio, streamIndex: stream.index, title: stream.label,
                                            language: stream.language, codec: stream.codec,
                                            isForced: nil, isDefault: stream.isDefault))
            }
        }
        if tracks.subtitles {
            for stream in source?.subtitleStreams ?? [] where stream.isTextSubtitle && (mbit != nil || stream.isExternal == true) {
                extras.append(DownloadExtra(kind: .subtitle, streamIndex: stream.index, title: stream.label,
                                            language: stream.language, codec: stream.codec,
                                            isForced: stream.isForced, isDefault: stream.isDefault))
            }
        }

        var record = DownloadRecord(
            id: item.id, name: item.name ?? "Untitled", subtitle: subtitle.isEmpty ? nil : subtitle,
            runTimeTicks: item.runTimeTicks, mbit: mbit, mediaSourceId: source?.id,
            fileName: nil, posterFileName: nil, state: .queued, progress: 0, bytesWritten: 0,
            expectedBytes: expected, errorMessage: nil, createdAt: .now
        )
        record.mainAudioIndex = mainAudio
        record.mainAudioTitle = mainAudio.flatMap { index in source?.audioStreams.first { $0.index == index }?.label }
        record.extras = extras.isEmpty ? nil : extras
        records.insert(record, at: 0)
        setEpisodeInfo(at: 0, from: item)
        saveIndex()
        DownloadDiagnostics.log("\(item.id): queued \(item.name ?? "") (\(record.qualityLabel)) with \(extras.filter { $0.kind == .audio }.count) extra audio track(s), \(extras.filter { $0.kind == .subtitle }.count) subtitle(s)")

        let posters = Self.posterCandidates(for: item, api: api)
        Task {
            await savePoster(from: posters, itemId: item.id)
            await saveSeriesPoster(for: item, api: api)
        }
        DownloadNotifications.requestAuthorizationIfNeeded()
        // Started from the foreground: the only moment iOS lets us ask to keep running afterwards.
        DownloadKeepAlive.begin(title: String(localized: "Downloading"), subtitle: item.name ?? "")
        pump()
        DownloadActivityController.start()
    }

    /// Tries a failed download again, picking up where it stopped.
    func retry(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .failed else { return }
        records[index].state = .queued
        records[index].errorMessage = nil
        records[index].retryCount = 0
        records[index].retryAfter = nil
        saveIndex()
        DownloadKeepAlive.begin(title: String(localized: "Downloading"), subtitle: records[index].name)
        pump()
        DownloadActivityController.start()
    }

    /// Pauses a queued or running download. What's been loaded is kept: the transfers in flight are
    /// cancelled with their resume data, so `resume` continues where it stopped (also after a relaunch).
    func pause(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else { return }
        records[index].state = .paused
        records[index].errorMessage = nil
        records[index].retryAfter = nil
        speeds[id] = nil
        speedSamples[id] = nil
        for key in liveKeys(of: id) {
            guard let task = liveTasks.removeValue(forKey: key) else { continue }
            inflightBytes[key] = nil
            inAppTasks.remove(ObjectIdentifier(task))
            abandonedTasks.insert(ObjectIdentifier(task))
            if let download = task as? URLSessionDownloadTask {
                pendingResumeData.insert(key)
                download.cancel { data in
                    if let data { try? data.write(to: Self.resumeDataURL(for: key), options: .atomic) }
                    Task { @MainActor in
                        self.pendingResumeData.remove(key)
                        self.pump()          // resumed meanwhile: it can start now
                    }
                }
            } else {
                task.cancel()
            }
        }
        if let hls = records[index].hls {
            records[index].bytesWritten = hls.bytes      // what's on disk; segments in flight count again on resume
        }
        saveIndex()
        DownloadDiagnostics.log("\(id): paused")
        pump()                                      // the next download in the queue can start
        DownloadActivityController.refresh(force: true)
    }

    /// Continues a paused download where it stopped (it joins the queue).
    func resume(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .paused else { return }
        records[index].state = .queued
        records[index].retryCount = nil
        records[index].retryAfter = nil
        saveIndex()
        DownloadDiagnostics.log("\(id): resumed")
        DownloadKeepAlive.begin(title: String(localized: "Downloading"), subtitle: records[index].name)
        pump()
        DownloadActivityController.start()
    }

    var hasPausedDownloads: Bool { records.contains { $0.state == .paused } }

    func pauseAll() {
        for record in records where record.isActive { pause(id: record.id) }
    }

    /// Resumes paused downloads in the order they were added (the queue starts the oldest first).
    func resumeAll() {
        for record in records where record.state == .paused { resume(id: record.id) }
    }

    /// Cancels a running or queued download or removes a finished one (all its files included).
    func delete(id: String) {
        for key in liveKeys(of: id) { liveTasks.removeValue(forKey: key)?.cancel(); inflightBytes[key] = nil }
        speeds[id] = nil
        // Video, segments, extras, resume data and poster all start with the id.
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        where name.hasPrefix("\(id).") || name.hasPrefix(".\(id).") || name.hasPrefix("\(id)-") {
            try? fileManager.removeItem(at: Self.directory.appendingPathComponent(name))
        }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let removed = records.remove(at: index)
        if let seriesId = removed.seriesId, !records.contains(where: { $0.seriesId == seriesId }) {
            try? fileManager.removeItem(at: Self.seriesPosterURL(seriesId))
        }
        saveIndex()
        pump()
        DownloadActivityController.refresh(force: true)
    }

    /// Plays a finished download with its extra audio tracks and subtitles, continuing where it stopped.
    /// - Parameter serverResumeSeconds: the server's resume point, used while the download itself
    ///   has never been played (it may have been watched by streaming or on another device).
    func play(_ record: DownloadRecord, title: String? = nil, serverResumeSeconds: Double? = nil) {
        guard let url = fileURL(for: record) else { return }
        WatchedStore.shared.forget(record.id, record.seriesId)
        let start = record.lastPlayedAt == nil ? (serverResumeSeconds ?? 0) : (record.resumeSeconds ?? 0)
        let tracks = extraFiles(for: record).map { file in
            PlaybackCoordinator.OfflineTrack(kind: file.extra.kind == .audio ? .audio : .subtitle, url: file.url,
                                             title: file.extra.title, language: file.extra.language)
        }
        PlaybackCoordinator.shared.playLocal(fileURL: url, itemId: record.id, startSeconds: start,
                                             title: title ?? record.name, subtitle: record.subtitle,
                                             posterURL: posterURL(for: record), tracks: tracks,
                                             embeddedAudioTitle: record.mainAudioTitle)
    }

    // MARK: - Watch progress

    /// Remembers how far a download was watched. `serverKnows`: the playback was streamed, so the
    /// server has the position already; otherwise (offline) it's sent once the server is reachable.
    func savePlayback(id: String, seconds: Double, duration: Double, serverKnows: Bool = false, syncNow: Bool = false) {
        guard let index = records.firstIndex(where: { $0.id == id }), seconds.isFinite else { return }
        let runtime = duration > 0 ? duration : Ticks.seconds(records[index].runTimeTicks ?? 0)
        // Like Jellyfin: past 90 % counts as watched; the first seconds don't count as a resume point.
        let finished = runtime > 0 && seconds >= runtime * 0.9
        guard finished || seconds >= 10 else { return }
        records[index].resumeSeconds = finished ? nil : seconds
        records[index].lastPlayedAt = .now
        if finished { records[index].watched = true }
        if !serverKnows { records[index].playStateNeedsSync = true }
        saveIndex()
        if syncNow, !serverKnows { syncPlayStates() }
    }

    /// Sends offline watch progress to the server (after offline playback, at launch, back in the app).
    func syncPlayStates() {
        let pending = records.filter { $0.playStateNeedsSync == true }
        guard !pending.isEmpty, let stored = SessionStorage.load() else { return }
        let api = JellyfinAPI(session: stored)
        Task {
            for record in pending {
                let finished = record.resumeSeconds == nil && record.watched == true
                do {
                    try await api.updatePlayState(itemId: record.id,
                                                  positionTicks: finished ? 0 : Ticks.ticks(record.resumeSeconds ?? 0),
                                                  played: finished ? true : nil,
                                                  lastPlayed: record.lastPlayedAt ?? .now)
                    guard let index = records.firstIndex(where: { $0.id == record.id }),
                          records[index].lastPlayedAt == record.lastPlayedAt else { continue }   // watched again meanwhile
                    records[index].playStateNeedsSync = nil
                    saveIndex()
                    DownloadDiagnostics.log("\(record.id): offline watch progress sent to the server")
                } catch {
                    downloadLog.notice("Play state sync for \(record.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    return      // probably offline: try again later
                }
            }
            NotificationCenter.default.post(name: .playbackDidStop, object: nil)    // screens reload the new position
        }
    }

    // MARK: - Queue

    /// Matches running transfers from the system to the index after (re)launch.
    private func reconnect(_ tasks: [URLSessionDownloadTask]) {
        // Without the index the tasks can't be matched; never cancel them blindly. Retried on unlock.
        guard !indexUnavailable else {
            downloadLog.notice("Index not readable yet (device locked); reconnect deferred")
            return
        }
        for task in tasks {
            guard let key = task.taskDescription, case let id = DownloadPart.parse(key).id,
                  let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else {
                task.cancel()           // deleted while the app was gone
                continue
            }
            liveTasks[key] = task
            records[index].state = .downloading
            attemptStartBytes[id] = records[index].bytesWritten
        }
        downloadLog.notice("Reconnected \(self.liveTasks.count) running download(s)")
        DownloadDiagnostics.log("App started: \(liveTasks.count) transfer(s) still running in iOS' download service")

        // Marked as downloading, but the system has no transfer for it: it finished or was cancelled
        // while the app was gone (closed from the app switcher), and that event – with the resume data
        // to continue from – arrives in a moment. Start the replacement only after a pause, so it
        // doesn't overtake that event; if the event brings resume data, it takes over (see `ended`).
        for index in records.indices where records[index].state == .downloading && liveKeys(of: records[index].id).isEmpty {
            records[index].state = .queued
            records[index].retryAfter = .now.addingTimeInterval(10)
        }
        saveIndex()
        isReconnected = true
        pump()
        DownloadActivityController.appLaunched()
        refreshEpisodeInfo()
        if eventsDelivered { callBackgroundCompletion() }
    }

    /// Starts queued downloads while there is room: ones already under way first, then the oldest.
    private func pump() {
        guard isReconnected else { return }
        while records.filter({ $0.state == .downloading }).count < Self.maxConcurrent,
              let index = records.lastIndex(where: { $0.state == .queued && $0.isUnderWay })
                ?? records.lastIndex(where: { $0.state == .queued }) {
            begin(at: index)
        }
        if !hasActiveDownloads { DownloadKeepAlive.end() }
    }

    /// What to fetch next for a download, or nil when everything is there.
    private func nextPart(of record: DownloadRecord) -> DownloadPart? {
        if record.fileName == nil {
            guard record.mbit != nil else { return .original }
            return nextHLSPart(of: record, .video)
        }
        guard let n = record.nextExtraIndex else { return nil }
        return extraUsesHLS(record, n) ? nextHLSPart(of: record, .extra(n)) : .extra(n)
    }

    /// Segment list, init segment, then the media segments in order (nil: all appended).
    private func nextHLSPart(of record: DownloadRecord, _ target: HLSTarget) -> DownloadPart? {
        guard let hls = hlsProgress(of: record, target),
              FileManager.default.fileExists(atPath: Self.hlsListURL(for: record.id, target).path) else {
            return .playlist(target)
        }
        if !hls.hasInitSegment { return .initSegment(target) }
        return hls.nextSegment < hls.segmentCount ? .segment(target, hls.nextSegment) : nil
    }

    /// What to request now: the next part, or for a transcode the next few segments (the init
    /// segment alone first – requesting it makes Jellyfin restart the transcode).
    private func partsToStart(of record: DownloadRecord) -> [DownloadPart] {
        guard let next = nextPart(of: record) else { return [] }
        guard let first = next.segmentNumber, let target = next.hlsTarget, let hls = hlsProgress(of: record, target) else {
            return [next]
        }
        return (first..<min(hls.segmentCount, first + Self.segmentPipeline))
            .map { DownloadPart.segment(target, $0) }
            .filter { readySegmentFile(id: record.id, $0) == nil }
    }

    private func begin(at index: Int) {
        // The app stopped right after the last segment was appended: just finish the file.
        if records[index].fileName == nil, hlsIsComplete(records[index], .video) {
            do { try finalizeHLS(at: index, .video) } catch { resetHLS(at: index, .video); return }
        } else if records[index].fileName != nil, let n = records[index].nextExtraIndex, hlsIsComplete(records[index], .extra(n)) {
            do { try finalizeHLS(at: index, .extra(n)) } catch { resetHLS(at: index, .extra(n)); return }
        }
        let record = records[index]
        let id = record.id
        // Just paused and resumed again: wait for the paused transfers' data (see `pause`).
        guard !pendingResumeData.contains(where: { DownloadPart.parse($0).id == id }) else { return }
        let live = Set(liveKeys(of: id))
        let parts = partsToStart(of: record).filter { !live.contains($0.key(for: id)) }
        if parts.isEmpty {
            if live.isEmpty {
                complete(at: index)     // nothing left (e.g. the last part finished while the app was gone)
            } else {
                records[index].state = .downloading
            }
            return
        }
        // The token comes from the Keychain (readable after first unlock), so this also works when
        // the app was relaunched in the background with the screen locked.
        guard let stored = SessionStorage.load() else {
            fail(at: index, message: String(localized: "Not signed in."))
            return
        }
        let api = JellyfinAPI(session: stored)
        if record.fileName == nil { prefetchSubtitles(id: id, api: api) }
        if parts.contains(where: { subtitleFetches.contains($0.key(for: id)) }) {
            // The subtitle is on its way already (fetched ahead): carries on when it's there.
            records[index].state = .downloading
            return
        }
        if parts.count == 1, case let part = parts[0], part == .playlist(part.hlsTarget ?? .video), let target = part.hlsTarget {
            fetchPlaylist(at: index, target, api: api)
            return
        }
        for part in parts {
            guard records[index].isActive else { return }
            startTransfer(part, at: index, api: api)
        }
        records[index].retryAfter = nil
        saveIndex()
        DownloadKeepAlive.update(title: String(localized: "Downloading"), subtitle: record.name)
    }

    private func startTransfer(_ part: DownloadPart, at index: Int, api: JellyfinAPI) {
        let record = records[index]
        let id = record.id
        let key = part.key(for: id)
        let url: URL
        let what: String
        switch part {
        case .original, .playlist:
            url = api.originalDownloadURL(itemId: id)
            what = "original file"
        case .initSegment, .segment, .extraInit, .extraSegment:
            let target = part.hlsTarget ?? .video
            guard let list = loadSegmentList(id: id, target) else {
                resetHLS(at: index, target)
                return
            }
            if let n = part.segmentNumber {
                guard list.segmentURLs.indices.contains(n),
                      let segmentURL = HLSSegmentList.url(list.segmentURLs[n], token: api.accessToken) else { resetHLS(at: index, target); return }
                url = segmentURL
                what = label(target, record) + "segment \(n + 1) of \(list.segmentURLs.count)"
            } else {
                guard let initURL = HLSSegmentList.url(list.initURL, token: api.accessToken) else { resetHLS(at: index, target); return }
                url = initURL
                what = label(target, record) + "init segment"
            }
        case .extraPlaylist:
            return          // fetched with a plain request (fetchPlaylist)
        case .extra(let n):
            guard let item = record.extras?[n] else { complete(at: index); return }
            switch item.kind {
            case .audio:
                url = api.audioTrackDownloadURL(itemId: id, mediaSourceId: record.mediaSourceId, audioStreamIndex: item.streamIndex,
                                                audioBitrate: JellyfinAPI.downloadAudioBitrate(forMbit: record.mbit ?? 4))
                what = "audio track \(item.streamIndex) (\(item.title))"
            case .subtitle:
                guard let subtitleURL = api.subtitleDownloadURL(itemId: id, mediaSourceId: record.mediaSourceId,
                                                                streamIndex: item.streamIndex, codec: item.codec) else {
                    skipExtra(at: index, extra: n, reason: "no media source")
                    return
                }
                url = subtitleURL
                what = "subtitle \(item.streamIndex) (\(item.title))"
            }
        }

        var request = URLRequest(url: url)
        request.setValue(api.authorizationHeader, forHTTPHeaderField: "Authorization")
        let inApp = useInAppSession
        let transferSession: URLSession = inApp ? inAppSession : session
        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: Self.resumeDataURL(for: key)) {
            // Picks up the bytes already on disk instead of starting over.
            task = transferSession.downloadTask(withResumeData: resumeData)
            try? FileManager.default.removeItem(at: Self.resumeDataURL(for: key))
            DownloadDiagnostics.log("\(id): resuming \(what)")
        } else {
            task = transferSession.downloadTask(with: request)
            if part == .original {
                records[index].bytesWritten = 0
                records[index].progress = 0
            }
            DownloadDiagnostics.log("\(id): starting \(what)\(inApp ? " (in the app, kept running in the background)" : "")")
        }
        task.taskDescription = key
        if part == .original, let expected = record.expectedBytes, expected > 0 {
            task.countOfBytesClientExpectsToReceive = expected
        }
        liveTasks[key] = task
        if attemptStartBytes[id] == nil { attemptStartBytes[id] = records[index].bytesWritten }
        records[index].state = .downloading
        let delay = record.retryAfter.map { $0.timeIntervalSinceNow } ?? 0
        if inApp {
            inAppTasks.insert(ObjectIdentifier(task))
            // The in-app session has no delayed start; wait here (a cancelled task ignores resume()).
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak task] in task?.resume() }
            } else {
                task.resume()
            }
        } else {
            // A retry waits out its backoff inside the system's download service, so it still happens
            // when the app is suspended in the background.
            if delay > 0 { task.earliestBeginDate = record.retryAfter }
            task.resume()
        }
    }

    // MARK: - Background: in-app transfers while kept running

    /// New transfers go through the in-app session while the app is in the background but kept
    /// running; in the foreground the background session starts them right away (and they survive
    /// the app being suspended or closed).
    private var useInAppSession: Bool {
        UIApplication.shared.applicationState == .background && DownloadKeepAlive.isRunning && !inAppBlocked
    }

    /// The keep-alive started or ended.
    func keepAliveChanged(running: Bool) {
        if running {
            inAppBlocked = false
        } else {
            handOverInAppTransfers(reason: "the background keep-alive ended")
        }
    }

    @objc private func appDidEnterBackground() {
        if DownloadKeepAlive.isRunning {
            DownloadDiagnostics.log("App in the background – kept running, downloads continue")
        } else {
            DownloadDiagnostics.log("App in the background without keep-alive – iOS' download service continues, but may postpone new parts")
        }
    }

    /// The app is about to be suspended: cancel the in-app transfers and start them again in the
    /// background session (originals continue from where they were), so iOS carries on with them.
    private func handOverInAppTransfers(reason: String) {
        let moving = liveTasks.filter { inAppTasks.contains(ObjectIdentifier($0.value)) }
        guard !moving.isEmpty else { return }
        if UIApplication.shared.applicationState == .background { inAppBlocked = true }
        DownloadDiagnostics.log("Handing \(moving.count) transfer(s) to iOS' download service – \(reason)")
        // A few seconds to finish the hand-over before iOS suspends the app.
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Download hand-over") {
            UIApplication.shared.endBackgroundTask(assertion)
        }
        var waiting = 0
        func done() {
            waiting -= 1
            guard waiting <= 0 else { return }
            saveIndex()
            pump()
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        }
        waiting = 1
        for (key, task) in moving {
            liveTasks[key] = nil
            inflightBytes[key] = nil
            inAppTasks.remove(ObjectIdentifier(task))
            abandonedTasks.insert(ObjectIdentifier(task))
            let (id, part) = DownloadPart.parse(key)
            if let index = records.firstIndex(where: { $0.id == id }), records[index].isActive {
                records[index].state = .queued
                records[index].retryAfter = nil
            }
            if part == .original, let download = task as? URLSessionDownloadTask {
                waiting += 1
                download.cancel { data in
                    Task { @MainActor in
                        if let data { try? data.write(to: Self.resumeDataURL(for: key), options: .atomic) }
                        done()
                    }
                }
            } else {
                task.cancel()       // a segment or extra file: fetched again in full
            }
        }
        done()
    }

    @objc private func appDidBecomeActive() {
        Self.prepareDirectory()
        retryDeferredIndex()
        inAppBlocked = false
        syncPlayStates()
        // After a relaunch the keep-alive isn't running yet; it can only be requested in the foreground.
        if let record = records.first(where: { $0.state == .downloading }) ?? records.first(where: { $0.isActive }) {
            DownloadKeepAlive.begin(title: String(localized: "Downloading"), subtitle: record.name)
        }
        pump()
        DownloadActivityController.start()
    }

    @objc private func protectedDataAvailable() {
        Self.prepareDirectory()
        retryDeferredIndex()
    }

    /// The iPhone was unlocked: read the index now, file what finished meanwhile and reconnect.
    private func retryDeferredIndex() {
        guard indexUnavailable else { return }
        loadIndex()
        guard !indexUnavailable else { return }
        downloadLog.notice("Index readable again; filing \(self.pendingCompletions.count) finished download(s)")
        let pending = pendingCompletions
        pendingCompletions = []
        for item in pending { finished(key: item.key, task: nil, fileName: item.fileName, size: item.size) }
        session.getAllTasks { tasks in
            let downloads = tasks.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor in self.reconnect(downloads) }
        }
    }

    // MARK: - HLS (transcoded downloads)

    /// Asks the server for the segment list of the transcode. Small and quick, so a plain request.
    private func fetchPlaylist(at index: Int, _ target: HLSTarget, api: JellyfinAPI) {
        let record = records[index]
        let id = record.id
        let fetchKey = DownloadPart.playlist(target).key(for: id)
        guard let mbit = record.mbit else { return }
        guard !playlistFetches.contains(fetchKey) else {
            // Already on its way (fetched ahead, see prefetchAudioPlaylists): carries on when it's there.
            records[index].state = .downloading
            return
        }
        let playSessionId = hlsProgress(of: record, target)?.playSessionId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url: URL
        switch target {
        case .video:
            url = api.hlsDownloadPlaylistURL(itemId: id, mediaSourceId: record.mediaSourceId, mbit: mbit,
                                             audioStreamIndex: record.mainAudioIndex, playSessionId: playSessionId)
        case .extra(let n):
            guard let extra = record.extras?[n] else { return }
            url = api.audioTrackHLSPlaylistURL(itemId: id, mediaSourceId: record.mediaSourceId, audioStreamIndex: extra.streamIndex,
                                               audioBitrate: JellyfinAPI.downloadAudioBitrate(forMbit: mbit), playSessionId: playSessionId)
        }
        var request = URLRequest(url: url)
        request.setValue(api.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        playlistFetches.insert(fetchKey)
        records[index].state = .downloading
        if target == .video {
            records[index].bytesWritten = 0
            records[index].progress = 0
        }
        saveIndex()
        DownloadDiagnostics.log("\(id): \(label(target, record))requesting the segment list (\(Bitrate.label(mbit)))")

        Task {
            // When the app goes to the background meanwhile, iOS gives it time to finish this request.
            let time = BackgroundTime("Segment list")
            defer { playlistFetches.remove(fetchKey); time.end() }
            var failure: NSError?
            var status: Int?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                status = (response as? HTTPURLResponse)?.statusCode
                if status == 200, let text = String(data: data, encoding: .utf8),
                   let list = HLSSegmentList.parse(text, relativeTo: url) {
                    try JSONEncoder().encode(list).write(to: Self.hlsListURL(for: id, target), options: .atomic)
                    guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else { return }
                    try? FileManager.default.removeItem(at: Self.hlsOutputURL(for: id, target))
                    setHLSProgress(HLSProgress(segmentCount: list.segmentURLs.count, nextSegment: 0,
                                               hasInitSegment: false, bytes: 0, playSessionId: playSessionId), at: index, target)
                    records[index].state = .queued
                    records[index].retryCount = nil
                    saveIndex()
                    DownloadDiagnostics.log("\(id): \(label(target, records[index]))\(list.segmentURLs.count) segments of \(JellyfinAPI.downloadSegmentSeconds) s")
                    if target == .video { prefetchAudioPlaylists(id: id, api: api) }
                    pump()
                    return
                }
                if status == 200 { failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotParseResponse) }
            } catch {
                failure = error as NSError
            }
            guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else { return }
            DownloadDiagnostics.log("\(id): segment list failed – " + (failure.map(DownloadDiagnostics.describe) ?? "HTTP \(status ?? 0)"))
            handleFailure(at: index, part: .playlist(target), task: nil, error: failure, httpStatus: failure == nil ? status : nil)
        }
    }

    /// Fetches the extra audio tracks' segment lists right after the video's, while the app is surely
    /// running. When the video is done – maybe in the background, with the iPhone locked, where a plain
    /// request can't run – the tracks go straight on with their segments in iOS' download service.
    /// If this fails, the list is simply requested again when the track is due.
    private func prefetchAudioPlaylists(id: String, api: JellyfinAPI) {
        guard let record = records.first(where: { $0.id == id }), let mbit = record.mbit, let extras = record.extras else { return }
        for n in extras.indices where extraUsesHLS(record, n) && hlsProgress(of: record, .extra(n)) == nil {
            let target = HLSTarget.extra(n)
            let fetchKey = DownloadPart.playlist(target).key(for: id)
            guard !playlistFetches.contains(fetchKey) else { continue }
            playlistFetches.insert(fetchKey)
            let playSessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let url = api.audioTrackHLSPlaylistURL(itemId: id, mediaSourceId: record.mediaSourceId, audioStreamIndex: extras[n].streamIndex,
                                                   audioBitrate: JellyfinAPI.downloadAudioBitrate(forMbit: mbit), playSessionId: playSessionId)
            var request = URLRequest(url: url)
            request.setValue(api.authorizationHeader, forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 60
            Task {
                let time = BackgroundTime("Segment list")
                defer { time.end() }
                var list: HLSSegmentList?
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) {
                    list = HLSSegmentList.parse(text, relativeTo: url)
                }
                playlistFetches.remove(fetchKey)
                guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else { return }
                if let list, hlsProgress(of: records[index], target) == nil,
                   (try? JSONEncoder().encode(list).write(to: Self.hlsListURL(for: id, target), options: .atomic)) != nil {
                    setHLSProgress(HLSProgress(segmentCount: list.segmentURLs.count, nextSegment: 0,
                                               hasInitSegment: false, bytes: 0, playSessionId: playSessionId), at: index, target)
                    DownloadDiagnostics.log("\(id): \(label(target, records[index]))\(list.segmentURLs.count) segments of \(JellyfinAPI.downloadSegmentSeconds) s (fetched ahead)")
                } else {
                    DownloadDiagnostics.log("\(id): \(label(target, records[index]))segment list not fetched ahead – requested when the track is due")
                }
                // The track may have been waiting for this.
                if records[index].state == .downloading, liveKeys(of: id).isEmpty {
                    records[index].state = .queued
                }
                saveIndex()
                pump()
            }
        }
    }

    /// Subtitles are small: they're fetched right at the start, next to the video, while the app is
    /// surely running (the user just tapped Download). Left for the end, they'd often be due in the
    /// background with the iPhone locked, where iOS may postpone new transfers for hours. If this
    /// fails, the subtitle is simply loaded after the video, with the usual retries.
    private func prefetchSubtitles(id: String, api: JellyfinAPI) {
        guard !indexUnavailable, !subtitlePrefetchStarted.contains(id),
              let record = records.first(where: { $0.id == id }), let extras = record.extras else { return }
        let pending = extras.indices.filter { extras[$0].kind == .subtitle && extras[$0].isPending }
        guard !pending.isEmpty else { return }
        subtitlePrefetchStarted.insert(id)
        for n in pending { subtitleFetches.insert(DownloadPart.extra(n).key(for: id)) }
        let mediaSourceId = record.mediaSourceId
        Task {
            // When the app goes to the background meanwhile, iOS gives it time to finish.
            let time = BackgroundTime("Subtitles")
            defer { time.end() }
            for n in pending {
                let key = DownloadPart.extra(n).key(for: id)
                let extra = extras[n]
                let what = "subtitle \(extra.streamIndex) (\(extra.title))"
                var result = "not fetched ahead"
                if let url = api.subtitleDownloadURL(itemId: id, mediaSourceId: mediaSourceId, streamIndex: extra.streamIndex, codec: extra.codec),
                   records.first(where: { $0.id == id })?.extras?[n].isPending == true {
                    var request = URLRequest(url: url)
                    request.setValue(api.authorizationHeader, forHTTPHeaderField: "Authorization")
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 600      // the server may first have to extract it from the file
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if (200..<300).contains(status), !data.isEmpty {
                            let ext = ((response.suggestedFilename as NSString?)?.pathExtension).flatMap { $0.isEmpty ? nil : $0 }
                                ?? (url.pathExtension.isEmpty ? "srt" : url.pathExtension)
                            let fileName = "\(key).\(ext.lowercased())"
                            if let index = records.firstIndex(where: { $0.id == id }), records[index].extras?.indices.contains(n) == true,
                               records[index].extras?[n].isPending == true, liveTasks[key] == nil,
                               (try? Self.storeSmallFile(data, as: fileName)) != nil {
                                records[index].extras?[n].fileName = fileName
                                reportKeepAliveProgress(of: records[index])
                                result = "stored (\(data.count) bytes, fetched ahead)"
                            }
                        } else {
                            result = "not fetched ahead (HTTP \(status)) – loaded after the video"
                        }
                    } catch {
                        result = "not fetched ahead (\(DownloadDiagnostics.describe(error as NSError))) – loaded after the video"
                    }
                }
                subtitleFetches.remove(key)
                guard let index = records.firstIndex(where: { $0.id == id }) else { continue }
                DownloadDiagnostics.log("\(id): \(what) \(result)")
                // The download may have been waiting for this subtitle.
                if records[index].state == .downloading, liveKeys(of: id).isEmpty {
                    records[index].state = .queued
                }
                saveIndex()
                pump()
            }
        }
    }

    /// Writes a small extra file (fetched with a plain request) into the download folder.
    private static func storeSmallFile(_ data: Data, as fileName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// All segments are appended: the grown file becomes the video (or the audio track's file).
    private func finalizeHLS(at index: Int, _ target: HLSTarget) throws {
        guard let hls = hlsProgress(of: records[index], target) else { return }
        let id = records[index].id
        let final: String
        switch target {
        case .video: final = "\(id).mp4"
        case .extra(let n): final = DownloadPart.extra(n).key(for: id) + ".mp4"
        }
        let destination = Self.directory.appendingPathComponent(final)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: Self.hlsOutputURL(for: id, target), to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = destination
        try? url.setResourceValues(values)
        try? FileManager.default.removeItem(at: Self.hlsListURL(for: id, target))
        if case .extra(let n) = target {
            records[index].extras?[n].fileName = final
            clearExtraProgress(at: index)
            DownloadDiagnostics.log("\(id): \(label(target, records[index]))assembled from \(hls.segmentCount) segments (\(hls.bytes) bytes)")
            return
        }
        records[index].fileName = final
        records[index].bytesWritten = hls.bytes
        records[index].expectedBytes = hls.bytes
        records[index].progress = 1
        DownloadDiagnostics.log("\(id): video assembled from \(hls.segmentCount) segments (\(hls.bytes) bytes)")
    }

    private func loadSegmentList(id: String, _ target: HLSTarget) -> HLSSegmentList? {
        guard let data = try? Data(contentsOf: Self.hlsListURL(for: id, target)) else { return nil }
        return try? JSONDecoder().decode(HLSSegmentList.self, from: data)
    }

    /// The segment list is gone or broken: start the segmented download over.
    private func resetHLS(at index: Int, _ target: HLSTarget) {
        let id = records[index].id
        setHLSProgress(nil, at: index, target)
        try? FileManager.default.removeItem(at: Self.hlsListURL(for: id, target))
        try? FileManager.default.removeItem(at: Self.hlsOutputURL(for: id, target))
        records[index].state = .queued
        saveIndex()
        DownloadDiagnostics.log("\(id): segment list missing – requesting it again")
        pump()
    }

    /// Appends a finished segment to the growing video. The file is first cut back to the size after
    /// the previous append, so a segment can never end up in it twice.
    private func appendSegment(_ segment: URL, at index: Int, _ target: HLSTarget, isInit: Bool) throws {
        guard var hls = hlsProgress(of: records[index], target) else { return }
        let output = Self.hlsOutputURL(for: records[index].id, target)
        let fileManager = FileManager.default
        if isInit || !fileManager.fileExists(atPath: output.path) {
            try? fileManager.removeItem(at: output)
            guard fileManager.createFile(atPath: output.path, contents: nil, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
            }
            hls.bytes = 0
            if !isInit { hls.hasInitSegment = false; hls.nextSegment = 0 }   // output lost: start over
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(hls.bytes))
        try handle.seekToEnd()
        let input = try FileHandle(forReadingFrom: segment)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try handle.synchronize()
        hls.bytes = Int64(try handle.offset())
        if isInit { hls.hasInitSegment = true } else { hls.nextSegment += 1 }
        setHLSProgress(hls, at: index, target)
        try? fileManager.removeItem(at: segment)
    }

    // MARK: - Events from the session (main actor)

    private func progressChanged(key: String, task: URLSessionTask, written: Int64, expected: Int64) {
        let (id, part) = DownloadPart.parse(key)
        guard liveTasks[key] === task, let index = records.firstIndex(where: { $0.id == id }) else { return }
        if records[index].errorMessage != nil { records[index].errorMessage = nil }     // data is flowing again
        switch part {
        case .extraInit, .extraSegment:
            // An extra audio track: its own progress bar, like the video's.
            inflightBytes[key] = (written, expected)
            if let n = part.extraIndex { updateAudioProgress(at: index, n) }
            updateSpeed(id: id, bytes: records[index].extraBytesWritten ?? 0)
            reportKeepAliveProgress(of: records[index])
            if Date.now.timeIntervalSince(lastIndexSave) > 10 { saveIndex() }
            return
        case .extra(let n):
            // A subtitle: small, but its own progress bar too.
            inflightBytes[key] = (written, expected)
            updateFileExtraProgress(at: index, n, written: written, expected: expected)
            updateSpeed(id: id, bytes: written)
            reportKeepAliveProgress(of: records[index])
            return
        case .extraPlaylist:
            reportKeepAliveProgress(of: records[index])
            return
        case .initSegment, .segment:
            guard let hls = records[index].hls else { return }
            inflightBytes[key] = (written, expected)
            let inflight = inflightBytes.filter { DownloadPart.parse($0.key).id == id }.values
            records[index].bytesWritten = hls.bytes + inflight.reduce(0) { $0 + $1.written }
            let fraction = inflight.reduce(0.0) { $0 + ($1.expected > 0 ? Double($1.written) / Double($1.expected) : 0) }
            records[index].progress = min(0.99, (Double(hls.nextSegment) + fraction) / Double(max(hls.segmentCount, 1)))
        case .original, .playlist:
            records[index].bytesWritten = written
            let total = expected > 0 ? expected : (records[index].expectedBytes ?? 0)
            if expected > 0 { records[index].expectedBytes = expected }
            if total > 0 { records[index].progress = min(0.99, Double(written) / Double(total)) }
        }
        let bytes = records[index].bytesWritten
        // A retry that gets real data through starts a fresh count.
        if (records[index].retryCount ?? 0) > 0, bytes - (attemptStartBytes[id] ?? 0) > 2 << 20 {
            records[index].retryCount = 0
        }

        updateSpeed(id: id, bytes: bytes)
        reportKeepAliveProgress(of: records[index])
        if Date.now.timeIntervalSince(lastIndexSave) > 10 { saveIndex() }
    }

    /// The transfer speed, smoothed. `bytes` counts what the current file (video or audio track) has so far.
    private func updateSpeed(id: String, bytes: Int64) {
        let now = Date.now
        if let sample = speedSamples[id], bytes >= sample.bytes {
            let elapsed = now.timeIntervalSince(sample.time)
            if elapsed >= 1 {
                let current = Double(bytes - sample.bytes) / elapsed
                speeds[id] = speeds[id].map { $0 * 0.6 + current * 0.4 } ?? current
                speedSamples[id] = (now, bytes)
            }
        } else {
            speedSamples[id] = (now, bytes)     // first sample, or the next file started
        }
    }

    /// Estimated size of an extra audio track: audio plus the tiny picture (see audioTrackHLSPlaylistURL).
    private static func estimatedTrackBytes(_ record: DownloadRecord) -> Int64 {
        guard let mbit = record.mbit else { return 0 }
        let seconds = Double(record.runTimeTicks ?? 0) / 10_000_000
        return Int64(Double(JellyfinAPI.downloadAudioBitrate(forMbit: mbit) + 60_000) / 8 * seconds)
    }

    /// Progress bar of the extra audio track that's loading: appended segments plus the ones in flight.
    private func updateAudioProgress(at index: Int, _ n: Int) {
        let record = records[index]
        guard record.extras?.indices.contains(n) == true, let hls = record.extras?[n].hls, hls.segmentCount > 0 else { return }
        let inflight = inflightBytes.filter { entry in
            let (id, part) = DownloadPart.parse(entry.key)
            return id == record.id && part.hlsTarget == .extra(n) && part.segmentNumber != nil
        }.values
        let fraction = inflight.reduce(0.0) { $0 + ($1.expected > 0 ? Double($1.written) / Double($1.expected) : 0) }
        records[index].extraBytesWritten = hls.bytes + inflight.reduce(0) { $0 + $1.written }
        records[index].extraProgress = min(0.99, (Double(hls.nextSegment) + fraction) / Double(hls.segmentCount))
        // From the bitrate at first, then from the segments that are there (the last one is shorter).
        records[index].extraExpectedBytes = hls.nextSegment >= 2
            ? Int64(Double(hls.bytes) / Double(hls.nextSegment) * Double(hls.segmentCount))
            : Self.estimatedTrackBytes(record)
    }

    /// Progress bar of an extra file loading in one piece (a subtitle). Converted subtitles may come
    /// without a size; then only the bytes are shown.
    private func updateFileExtraProgress(at index: Int, _ n: Int, written: Int64, expected: Int64) {
        guard records[index].nextExtraIndex == n else { return }
        records[index].extraBytesWritten = written
        records[index].extraExpectedBytes = expected > 0 ? expected : nil
        records[index].extraProgress = expected > 0 ? min(0.99, Double(written) / Double(expected)) : nil
    }

    private func clearExtraProgress(at index: Int) {
        records[index].extraProgress = nil
        records[index].extraBytesWritten = nil
        records[index].extraExpectedBytes = nil
        speedSamples[records[index].id] = nil
    }

    /// iOS ends the keep-alive when its progress stops moving, so it follows the whole download: the
    /// video and the extra audio tracks, each weighted by its (estimated) size.
    private func reportKeepAliveProgress(of record: DownloadRecord) {
        // Weights that don't change while it runs (the real size replaces the estimate once the video is done).
        let videoBytes = record.mbit.flatMap { Bitrate.estimatedBytes(mbit: $0, runTimeTicks: record.runTimeTicks) }
            ?? record.expectedBytes ?? 1
        var parts: [(weight: Double, done: Double)] = [
            (Double(max(videoBytes, 1)), record.fileName != nil ? 1 : record.progress),
        ]
        if record.mbit != nil, let extras = record.extras {
            let trackBytes = Double(max(Self.estimatedTrackBytes(record), 1))
            for n in extras.indices where extras[n].kind == .audio {
                let done: Double
                if extras[n].fileName != nil || extras[n].skipped == true {
                    done = 1
                } else if let hls = extras[n].hls {
                    let inflight = inflightBytes.reduce(0.0) { sum, entry in
                        let (id, part) = DownloadPart.parse(entry.key)
                        guard id == record.id, part.hlsTarget == .extra(n), part.segmentNumber != nil, entry.value.expected > 0 else { return sum }
                        return sum + Double(entry.value.written) / Double(entry.value.expected)
                    }
                    done = min(1, (Double(hls.nextSegment) + inflight) / Double(max(hls.segmentCount, 1)))
                } else {
                    done = 0
                }
                parts.append((trackBytes, done))
            }
        }
        // Subtitles too, so the progress doesn't reach the end (and iOS end the keep-alive) before they're there.
        for n in (record.extras ?? []).indices where record.extras?[n].kind == .subtitle {
            let extra = record.extras![n]
            var done: Double = extra.isPending ? 0 : 1
            if extra.isPending, let inflight = inflightBytes[DownloadPart.extra(n).key(for: record.id)], inflight.expected > 0 {
                done = min(1, Double(inflight.written) / Double(inflight.expected))
            }
            parts.append((Double(max(videoBytes, 1)) * 0.01, done))
        }
        let weight = parts.reduce(0) { $0 + $1.weight }
        let fraction = parts.reduce(0) { $0 + $1.weight * $1.done } / weight
        // Never backwards (a segment that finishes before the one in front of it dips the estimate).
        var units = Int64(fraction * 100_000)
        if keepAliveReported.id == record.id { units = max(units, keepAliveReported.units) }
        keepAliveReported = (record.id, units)
        DownloadKeepAlive.progress(completed: units, total: 100_000)
    }

    private func finished(key: String, task: URLSessionTask?, fileName: String, size: Int64) {
        if indexUnavailable {
            pendingCompletions.append((key, fileName, size))    // keep the file; filed after unlock
            return
        }
        let (id, part) = DownloadPart.parse(key)
        let file = Self.directory.appendingPathComponent(fileName)
        if let task {
            inAppTasks.remove(ObjectIdentifier(task))
            abandonedTasks.remove(ObjectIdentifier(task))
        }
        if let current = liveTasks[key], current !== task {     // a duplicate attempt lost the race
            abandonedTasks.insert(ObjectIdentifier(current))
            inAppTasks.remove(ObjectIdentifier(current))
            current.cancel()
        }
        liveTasks[key] = nil
        inflightBytes[key] = nil
        // A part that finished just as the download was paused is kept; nothing new starts then.
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].isActive || records[index].state == .paused else {
            try? FileManager.default.removeItem(at: file)
            clearTransient(id)
            pump()
            return
        }
        let isPaused = records[index].state == .paused
        records[index].errorMessage = nil
        records[index].retryAfter = nil

        switch part {
        case .initSegment, .segment, .extraInit, .extraSegment:
            let target = part.hlsTarget ?? .video
            if let n = part.segmentNumber, let hls = hlsProgress(of: records[index], target), n != hls.nextSegment {
                // Arrived before the segment in front of it; appended once that one is there.
                guard n > hls.nextSegment else { try? FileManager.default.removeItem(at: file); break }
                break
            }
            do {
                try appendSegment(file, at: index, target, isInit: part.isInitSegment)
                // Segments that arrived early can follow now.
                while let hls = hlsProgress(of: records[index], target), hls.hasInitSegment, hls.nextSegment < hls.segmentCount,
                      let ready = readySegmentFile(id: id, .segment(target, hls.nextSegment)) {
                    try appendSegment(ready, at: index, target, isInit: false)
                }
            } catch {
                DownloadDiagnostics.log("\(id): couldn't append \(key) – \(DownloadDiagnostics.describe(error as NSError))")
                handleFailure(at: index, part: part, task: task, error: error as NSError, httpStatus: nil)
                return
            }
            if let hls = hlsProgress(of: records[index], target) {
                inflightBytes = inflightBytes.filter { DownloadPart.parse($0.key).id != id || liveTasks[$0.key] != nil }
                if target == .video { records[index].bytesWritten = hls.bytes }
                if hls.nextSegment == 1 || hls.nextSegment % 20 == 0 {
                    DownloadDiagnostics.log("\(id): \(label(target, records[index]))\(hls.nextSegment) of \(hls.segmentCount) segments")
                }
            }
            // Data gets through: interruptions before don't count against the retries any more.
            if case .extra(let n) = target {
                records[index].retryCount = nil
                updateAudioProgress(at: index, n)
                reportKeepAliveProgress(of: records[index])
            }
            if hlsIsComplete(records[index], target) {
                do {
                    try finalizeHLS(at: index, target)
                } catch {
                    handleFailure(at: index, part: part, task: task, error: error as NSError, httpStatus: nil)
                    return
                }
            }
        case .extraPlaylist:
            break
        case .extra(let n):
            if records[index].extras?.indices.contains(n) == true {
                records[index].extras?[n].fileName = fileName
                records[index].retryCount = nil
                clearExtraProgress(at: index)
                reportKeepAliveProgress(of: records[index])
                DownloadDiagnostics.log("\(id): extra \(n) stored (\(size) bytes)")
            }
        case .original, .playlist:
            records[index].fileName = fileName
            records[index].bytesWritten = size
            records[index].expectedBytes = size
            records[index].progress = 1
            DownloadDiagnostics.log("\(id): video stored (\(size) bytes)")
        }

        if nextPart(of: records[index]) != nil || !liveKeys(of: id).isEmpty {
            saveIndex()
            if !isPaused { begin(at: index) }        // next part(s); keeps the pipeline full
        } else {
            clearTransient(id)
            complete(at: index)
        }
    }

    private func complete(at index: Int) {
        let id = records[index].id
        records[index].state = .completed
        records[index].progress = 1
        records[index].errorMessage = nil
        records[index].retryCount = nil
        records[index].retryAfter = nil
        saveIndex()
        downloadLog.notice("Finished \(id, privacy: .public)")
        DownloadDiagnostics.log("\(id): completed")
        DownloadNotifications.post(title: String(localized: "Download Complete"), body: records[index].name, id: id)
        pump()
        DownloadActivityController.refresh(force: true)
    }

    /// An extra file the server can't deliver doesn't fail the whole download.
    private func skipExtra(at index: Int, extra: Int, reason: String) {
        let id = records[index].id
        records[index].extras?[extra].skipped = true
        clearExtraProgress(at: index)
        if extraUsesHLS(records[index], extra) {
            try? FileManager.default.removeItem(at: Self.hlsListURL(for: id, .extra(extra)))
            try? FileManager.default.removeItem(at: Self.hlsOutputURL(for: id, .extra(extra)))
        }
        records[index].retryCount = nil
        records[index].retryAfter = nil
        records[index].errorMessage = nil
        DownloadDiagnostics.log("\(id): skipping extra \(extra) – \(reason)")
        if nextPart(of: records[index]) != nil {
            records[index].state = .queued
            saveIndex()
            pump()
        } else {
            complete(at: index)
        }
    }

    /// The transfer ended without a file (network error, server error, cancellation).
    private func ended(key: String, task: URLSessionTask, error: NSError?, httpStatus: Int?) {
        let resumeData = error?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if indexUnavailable {
            // Keep the partial data; after unlock the download is requeued and resumes from it.
            if let resumeData { try? resumeData.write(to: Self.resumeDataURL(for: key), options: .atomic) }
            return
        }
        inAppTasks.remove(ObjectIdentifier(task))
        if abandonedTasks.remove(ObjectIdentifier(task)) != nil {
            // Cancelled on purpose (handed over to the background session, or a duplicate).
            return
        }
        let (id, part) = DownloadPart.parse(key)
        if let current = liveTasks[key], current !== task {
            // An older transfer, typically cancelled when the app was closed, reporting only now. If it
            // brings resume data and the replacement hasn't got further, continue from it instead.
            if let resumeData, let index = records.firstIndex(where: { $0.id == id }), records[index].isActive,
               nextPart(of: records[index]) == part,
               current.countOfBytesReceived < max(task.countOfBytesReceived, 1 << 20) {
                try? resumeData.write(to: Self.resumeDataURL(for: key), options: .atomic)
                liveTasks[key] = nil
                current.cancel()
                records[index].state = .queued
                records[index].retryAfter = nil
                saveIndex()
                DownloadDiagnostics.log("\(id): continuing the closed transfer from \(task.countOfBytesReceived) bytes")
                pump()
            }
            return
        }
        liveTasks[key] = nil
        inflightBytes[key] = nil
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else {
            try? FileManager.default.removeItem(at: Self.resumeDataURL(for: key))
            pump()
            return
        }
        // Keep what was transferred so the next attempt continues from there; but if storing the file
        // was the problem, start the next attempt clean.
        if let error, Self.isStorageError(error) {
            try? FileManager.default.removeItem(at: Self.resumeDataURL(for: key))
        } else if let resumeData {
            try? resumeData.write(to: Self.resumeDataURL(for: key), options: .atomic)
            DownloadDiagnostics.log("\(id): kept \(task.countOfBytesReceived) bytes to continue from")
        }
        handleFailure(at: index, part: part, task: task, error: error, httpStatus: httpStatus)
    }

    /// Retry with backoff, or give up: a failed extra file is skipped, anything else fails the download
    /// (keeping its progress, so "Retry" continues where it stopped).
    private func handleFailure(at index: Int, part: DownloadPart, task: URLSessionTask?, error: NSError?, httpStatus: Int?) {
        let id = records[index].id
        func giveUp(_ message: String) {
            if let n = part.extraIndex {
                skipExtra(at: index, extra: n, reason: message)
            } else {
                fail(at: index, message: message)
                pump()
            }
        }
        let isExtra: Bool = { if case .extra = part { return true } else { return false } }()

        if let error, Self.isStorageError(error), !UIApplication.shared.isProtectedDataAvailable {
            // The iPhone is locked and its storage isn't writable right now. Not a real failure: try
            // again in a minute without using up the retry budget.
            records[index].state = .queued
            records[index].retryAfter = .now.addingTimeInterval(60)
            records[index].errorMessage = String(localized: "iPhone locked – trying again shortly")
            saveIndex()
            pump()
            return
        }
        if let httpStatus, !Self.isRetryable(status: httpStatus) {
            giveUp(Self.message(forStatus: httpStatus))
            return
        }
        if let error, !Self.isRetryable(error), !Self.isStorageError(error) {
            giveUp(error.localizedDescription)
            return
        }
        let attempt = (records[index].retryCount ?? 0) + 1
        // A dropped or missing connection isn't the server's fault: keep waiting for it much longer
        // (about two hours at the longest wait) instead of giving up after a few minutes.
        // A subtitle the server can't extract fails the same way each time: give up on it a bit sooner.
        let limit = error.map(Self.isConnectivityError) == true ? Self.maxConnectivityRetries
            : isExtra && (httpStatus ?? 0) >= 500 ? Self.maxExtraServerRetries : Self.maxRetries
        guard attempt <= limit else {
            giveUp(httpStatus.map(Self.message(forStatus:)) ?? error?.localizedDescription ?? String(localized: "Download failed."))
            return
        }
        // Closed app, network loss, server hiccup: wait a bit, then try again. The wait happens in the
        // download service (earliestBeginDate), so it also works while the app is suspended.
        let cancelledBySystem = error?.code == NSURLErrorCancelled
        let delay = cancelledBySystem ? 0 : min(60, pow(2, Double(attempt - 1)))
        records[index].retryCount = attempt
        records[index].state = .queued
        records[index].retryAfter = delay > 0 ? .now.addingTimeInterval(delay) : nil
        let reason = httpStatus.map(Self.message(forStatus:)) ?? error?.localizedDescription ?? ""
        records[index].errorMessage = String(localized: "Retrying (\(attempt)/\(limit)): \(reason)")
        downloadLog.notice("Retrying \(id, privacy: .public) in \(delay) s (attempt \(attempt))")
        DownloadDiagnostics.log("\(id): \(part.key(for: id)) interrupted, retry \(attempt)/\(limit) in \(Int(delay)) s – \(reason)")
        saveIndex()
        pump()
    }

    private func fail(at index: Int, message: String) {
        let id = records[index].id
        for key in liveKeys(of: id) { liveTasks.removeValue(forKey: key)?.cancel(); inflightBytes[key] = nil }
        records[index].state = .failed
        records[index].errorMessage = message
        records[index].retryAfter = nil
        saveIndex()
        downloadLog.error("Failed \(id, privacy: .public): \(message, privacy: .public)")
        DownloadDiagnostics.log("\(id): failed – \(message)")
        DownloadNotifications.post(title: String(localized: "Download Failed"),
                                   body: "\(records[index].name) – \(message)", id: id)
        DownloadActivityController.refresh(force: true)
    }

    private func clearTransient(_ id: String) {
        speeds[id] = nil
        speedSamples[id] = nil
        attemptStartBytes[id] = nil
    }

    fileprivate func sessionEventsDelivered() {
        eventsDelivered = true
        // Before reconnecting, the next queued download can't start yet; iOS suspends the app as soon
        // as the handler is called, so hold it until then.
        if isReconnected || indexUnavailable { callBackgroundCompletion() }
    }

    private func callBackgroundCompletion() {
        eventsDelivered = false
        saveIndex()
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    // MARK: - Errors

    /// Errors writing the file on the iPhone (often data protection while locked), as opposed to the
    /// server or the network. Retried, since they are usually gone once the iPhone is unlocked.
    private static func isStorageError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain {
            return [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteUnknownError,
                    NSFileReadUnknownError, NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        }
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotWriteToFile,
                NSURLErrorCannotMoveFile, NSURLErrorCannotCloseFile, NSURLErrorCannotRemoveFile,
                NSURLErrorNoPermissionsToReadFile].contains(error.code)
    }

    private static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || status >= 500
    }

    /// The connection dropped or isn't there (as opposed to the server refusing the request).
    private static func isConnectivityError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorCallIsActive,
                NSURLErrorBackgroundSessionWasDisconnected, NSURLErrorSecureConnectionFailed].contains(error.code)
    }

    private static func isRetryable(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorUserAuthenticationRequired,
             NSURLErrorUserCancelledAuthentication, NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile,
             NSURLErrorCannotWriteToFile, NSURLErrorCannotMoveFile, NSURLErrorNoPermissionsToReadFile,
             NSURLErrorFileDoesNotExist, NSURLErrorAppTransportSecurityRequiresSecureConnection,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot:
            return false
        default:
            return true     // lost connection, timeouts, DNS, cancellation by the system, …
        }
    }

    nonisolated private static func message(forStatus status: Int) -> String {
        switch status {
        case 401: String(localized: "Not signed in (HTTP 401).")
        case 403: String(localized: "Your user isn't allowed to download or transcode (HTTP 403).")
        default: String(localized: "Server returned HTTP \(status).")
        }
    }

    // MARK: - Storage

    /// The poster for the download list: an episode shows its season's poster, or the series' if the
    /// season has none, instead of the episode still; anything else its own poster.
    private static func posterCandidates(for item: BaseItem, api: JellyfinAPI) -> [(url: URL, source: String)] {
        var candidates: [(URL, String)] = []
        if item.type == "Episode" {
            if let seasonId = item.seasonId {
                candidates.append((api.imageURL(itemId: seasonId, type: "Primary", tag: nil, maxWidth: 300), "season"))
            }
            if let seriesId = item.seriesId {
                candidates.append((api.imageURL(itemId: seriesId, type: "Primary", tag: item.seriesPrimaryImageTag, maxWidth: 300), "series"))
            }
        }
        if let own = api.posterURL(for: item, maxWidth: 300) { candidates.append((own, "item")) }
        return candidates
    }

    /// Saves the first candidate the server has an image for.
    private func savePoster(from candidates: [(url: URL, source: String)], itemId: String) async {
        for candidate in candidates {
            guard let (data, response) = try? await URLSession.shared.data(from: candidate.url),
                  (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { continue }
            let name = "\(itemId)-poster.jpg"
            do {
                try data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
                guard let index = records.firstIndex(where: { $0.id == itemId }) else { return }
                records[index].posterFileName = name
                records[index].posterSource = candidate.source
                saveIndex()
            } catch {}
            return
        }
    }

    /// Episodes downloaded before season/series posters were used still show the episode still:
    /// fetch the right poster once (when the server is reachable; otherwise next launch).
    private func refreshEpisodeInfo() {
        // Episodes without the season/series poster or without series and season (downloaded before
        // those were stored), and series folders still without their poster.
        let pending = records.filter {
            $0.subtitle != nil && ($0.posterSource == nil || $0.seriesName == nil
                || ($0.seriesId.map { !FileManager.default.fileExists(atPath: Self.seriesPosterURL($0).path) } ?? false))
        }.map(\.id)
        guard !pending.isEmpty, let stored = SessionStorage.load() else { return }
        let api = JellyfinAPI(session: stored)
        Task {
            for id in pending {
                guard let item = try? await api.item(id: id) else { continue }
                guard item.type == "Episode" else {
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index].posterSource = "item"; saveIndex() }
                    continue
                }
                if let index = records.firstIndex(where: { $0.id == id }), records[index].seriesName == nil {
                    setEpisodeInfo(at: index, from: item)
                    saveIndex()
                }
                if records.first(where: { $0.id == id })?.posterSource == nil {
                    await savePoster(from: Self.posterCandidates(for: item, api: api), itemId: id)
                }
                await saveSeriesPoster(for: item, api: api)
            }
        }
    }

    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: Self.indexURL.path) else {
            indexUnavailable = false
            return
        }
        do {
            let data = try Data(contentsOf: Self.indexURL)
            records = (try? JSONDecoder().decode([DownloadRecord].self, from: data)) ?? records
            indexUnavailable = false
        } catch {
            // Exists but can't be read: protected while the iPhone is locked. Don't treat it as empty.
            indexUnavailable = true
            downloadLog.error("Index unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveIndex() {
        guard !indexUnavailable else { return }     // would overwrite the real index with an empty list
        lastIndexSave = .now
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}

private extension DownloadRecord {
    /// Part of it is already there (segments, the video before its extras, a retry).
    var isUnderWay: Bool { (retryCount ?? 0) > 0 || fileName != nil || (hls?.nextSegment ?? 0) > 0 || hls?.hasInitSegment == true }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor in
            self.progressChanged(key: key, task: downloadTask, written: totalBytesWritten,
                                 expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        // A 4xx/5xx still "finishes" — the file is the server's error page, not the video.
        guard (200..<300).contains(status) else {
            DownloadDiagnostics.log("\(key): server answered HTTP \(status)")
            Task { @MainActor in self.ended(key: key, task: downloadTask, error: nil, httpStatus: status) }
            return
        }

        // The file at `location` is deleted when this method returns, so store it synchronously.
        let suggestedExt = (response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        let fileName = "\(key).\(suggestedExt.isEmpty ? "mp4" : suggestedExt.lowercased())"
        let destination = Self.directory.appendingPathComponent(fileName)
        do {
            try Self.store(location, at: destination, key: key)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true      // large and re-downloadable; keep it out of iCloud backups
            var url = destination
            try? url.setResourceValues(values)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { @MainActor in self.finished(key: key, task: downloadTask, fileName: fileName, size: size) }
        } catch {
            let nsError = error as NSError
            DownloadDiagnostics.log("\(key): couldn't store the file from \(location.path) – \(DownloadDiagnostics.describe(nsError))")
            Task { @MainActor in self.ended(key: key, task: downloadTask, error: nsError, httpStatus: nil) }
        }
    }

    /// Moves the finished file into the download folder. Some installs only get read access to the
    /// file iOS hands over, so moving fails ("no permission"); then it is copied, and as a last resort
    /// read and written in chunks.
    nonisolated private static func store(_ location: URL, at destination: URL, key: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        let moveError: NSError
        do {
            try fileManager.moveItem(at: location, to: destination)
            return
        } catch {
            moveError = error as NSError
            DownloadDiagnostics.log("\(key): move failed – \(DownloadDiagnostics.describe(moveError)); copying instead")
        }
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: location, to: destination)
            try? fileManager.removeItem(at: location)
            return
        } catch {
            DownloadDiagnostics.log("\(key): copy failed – \(DownloadDiagnostics.describe(error as NSError)); streaming instead")
        }
        try? fileManager.removeItem(at: destination)
        let input = try FileHandle(forReadingFrom: location)
        defer { try? input.close() }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else { throw moveError }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        do {
            while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        try? fileManager.removeItem(at: location)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is handled in didFinishDownloadingTo.
        guard let error, let key = task.taskDescription else { return }
        let nsError = error as NSError
        downloadLog.notice("Task \(key, privacy: .public) ended: \(nsError.domain, privacy: .public) \(nsError.code)")
        DownloadDiagnostics.log("\(key): transfer ended after \(task.countOfBytesReceived) bytes – \(DownloadDiagnostics.describe(nsError))")
        Task { @MainActor in self.ended(key: key, task: task, error: nsError, httpStatus: nil) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Queued behind the event handlers above on the main actor, so the index is saved first.
        Task { @MainActor in self.sessionEventsDelivered() }
    }
}

// MARK: - Notifications

/// Tells the user when a download finishes or fails while the app isn't open.
enum DownloadNotifications {
    private static let askedKey = "downloadNotificationsAsked"

    @MainActor static func requestAuthorizationIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor static func post(title: String, body: String, id: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "download-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// A little time from iOS to finish a short request (such as a segment list) if the app goes to the
/// background meanwhile; `end()` when it's done.
@MainActor
final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { self.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
