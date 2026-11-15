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
    /// Segments requested at once. More would make Jellyfin restart the transcode: it does once a
    /// request is more than 24 s / segment length ahead of what it is encoding.
    private static let segmentPipeline = 2

    private(set) var records: [DownloadRecord] = []
    /// Current transfer speed in bytes per second, by item id.
    private(set) var speeds: [String: Double] = [:]

    /// Handed over by the app delegate when iOS wakes the app for this session; called once all
    /// pending events are delivered.
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    @ObservationIgnored private var session: URLSession!
    /// For transfers started while the app is kept running in the background (see the type's notes).
    @ObservationIgnored private var inAppSession: URLSession!
    /// Transfers running in `inAppSession`; they end with the app, so they are handed over in time.
    @ObservationIgnored private var inAppTasks: Set<ObjectIdentifier> = []
    /// Transfers cancelled on purpose (handed over, or a duplicate); their end is not a failure.
    @ObservationIgnored private var abandonedTasks: Set<ObjectIdentifier> = []
    /// iOS ended the keep-alive: no new in-app transfers until the app is back in the foreground.
    @ObservationIgnored private var inAppBlocked = false
    /// Running transfers by key (a transcode has up to `segmentPipeline` segments in flight).
    @ObservationIgnored private var liveTasks: [String: URLSessionTask] = [:]
    /// Bytes received so far by segments in flight, for the progress bar.
    @ObservationIgnored private var inflightBytes: [String: (written: Int64, expected: Int64)] = [:]
    @ObservationIgnored private var playlistFetches: Set<String> = []
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

    /// The segmented video while it grows, and its segment list.
    private static func hlsOutputURL(for id: String) -> URL { directory.appendingPathComponent(".\(id).hls.mp4") }
    private static func hlsListURL(for id: String) -> URL { directory.appendingPathComponent(".\(id).hls.json") }

    private func liveKeys(of id: String) -> [String] {
        liveTasks.keys.filter { DownloadPart.parse($0).id == id }
    }

    /// A segment that arrived before the one in front of it waits on disk as "<id>.seg<n>.<ext>".
    private func readySegmentFile(id: String, segment n: Int) -> URL? {
        let prefix = "\(id).seg\(n)."
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
        saveIndex()
        DownloadDiagnostics.log("\(item.id): queued \(item.name ?? "") (\(record.qualityLabel)) with \(extras.filter { $0.kind == .audio }.count) extra audio track(s), \(extras.filter { $0.kind == .subtitle }.count) subtitle(s)")

        let posters = Self.posterCandidates(for: item, api: api)
        Task { await savePoster(from: posters, itemId: item.id) }
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
        records.remove(at: index)
        saveIndex()
        pump()
        DownloadActivityController.refresh(force: true)
    }

    /// Plays a finished download with its extra audio tracks and subtitles.
    func play(_ record: DownloadRecord, title: String? = nil) {
        guard let url = fileURL(for: record) else { return }
        let tracks = extraFiles(for: record).map { file in
            PlaybackCoordinator.OfflineTrack(kind: file.extra.kind == .audio ? .audio : .subtitle, url: file.url,
                                             title: file.extra.title, language: file.extra.language)
        }
        PlaybackCoordinator.shared.playLocal(fileURL: url, title: title ?? record.name, subtitle: record.subtitle,
                                             posterURL: posterURL(for: record), tracks: tracks,
                                             embeddedAudioTitle: record.mainAudioTitle)
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
        refreshEpisodePosters()
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
            guard let hls = record.hls, FileManager.default.fileExists(atPath: Self.hlsListURL(for: record.id).path) else {
                return .playlist
            }
            if !hls.hasInitSegment { return .initSegment }
            return hls.nextSegment < hls.segmentCount ? .segment(hls.nextSegment) : nil
        }
        return record.nextExtraIndex.map { .extra($0) }
    }

    /// What to request now: the next part, or for a transcode the next few segments (the init
    /// segment alone first – requesting it makes Jellyfin restart the transcode).
    private func partsToStart(of record: DownloadRecord) -> [DownloadPart] {
        guard let next = nextPart(of: record) else { return [] }
        guard case .segment(let first) = next, let hls = record.hls else { return [next] }
        return (first..<min(hls.segmentCount, first + Self.segmentPipeline))
            .filter { readySegmentFile(id: record.id, segment: $0) == nil }
            .map { .segment($0) }
    }

    private func begin(at index: Int) {
        if records[index].fileName == nil, records[index].hlsIsComplete {
            // The app stopped right after the last segment was appended: just finish the file.
            do { try finalizeHLS(at: index) } catch { resetHLS(at: index); return }
        }
        let record = records[index]
        let id = record.id
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
        if parts == [.playlist] {
            fetchPlaylist(at: index, api: api)
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
        case .initSegment, .segment:
            guard let list = loadSegmentList(id: id) else {
                resetHLS(at: index)
                return
            }
            if case .segment(let n) = part {
                guard list.segmentURLs.indices.contains(n),
                      let segmentURL = HLSSegmentList.url(list.segmentURLs[n], token: api.accessToken) else { resetHLS(at: index); return }
                url = segmentURL
                what = "segment \(n + 1) of \(list.segmentURLs.count)"
            } else {
                guard let initURL = HLSSegmentList.url(list.initURL, token: api.accessToken) else { resetHLS(at: index); return }
                url = initURL
                what = "init segment"
            }
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
    private func fetchPlaylist(at index: Int, api: JellyfinAPI) {
        let record = records[index]
        let id = record.id
        guard let mbit = record.mbit, !playlistFetches.contains(id) else { return }
        let playSessionId = record.hls?.playSessionId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url = api.hlsDownloadPlaylistURL(itemId: id, mediaSourceId: record.mediaSourceId, mbit: mbit,
                                             audioStreamIndex: record.mainAudioIndex, playSessionId: playSessionId)
        var request = URLRequest(url: url)
        request.setValue(api.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        playlistFetches.insert(id)
        records[index].state = .downloading
        records[index].bytesWritten = 0
        records[index].progress = 0
        saveIndex()
        DownloadDiagnostics.log("\(id): requesting the segment list (\(Bitrate.label(mbit)))")

        Task {
            defer { playlistFetches.remove(id) }
            var failure: NSError?
            var status: Int?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                status = (response as? HTTPURLResponse)?.statusCode
                if status == 200, let text = String(data: data, encoding: .utf8),
                   let list = HLSSegmentList.parse(text, relativeTo: url) {
                    try JSONEncoder().encode(list).write(to: Self.hlsListURL(for: id), options: .atomic)
                    guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else { return }
                    try? FileManager.default.removeItem(at: Self.hlsOutputURL(for: id))
                    records[index].hls = HLSProgress(segmentCount: list.segmentURLs.count, nextSegment: 0,
                                                     hasInitSegment: false, bytes: 0, playSessionId: playSessionId)
                    records[index].state = .queued
                    records[index].retryCount = nil
                    saveIndex()
                    DownloadDiagnostics.log("\(id): \(list.segmentURLs.count) segments of \(JellyfinAPI.downloadSegmentSeconds) s")
                    pump()
                    return
                }
                if status == 200 { failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotParseResponse) }
            } catch {
                failure = error as NSError
            }
            guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else { return }
            DownloadDiagnostics.log("\(id): segment list failed – " + (failure.map(DownloadDiagnostics.describe) ?? "HTTP \(status ?? 0)"))
            handleFailure(at: index, part: .playlist, task: nil, error: failure, httpStatus: failure == nil ? status : nil)
        }
    }

    /// All segments are appended: the grown file becomes the video.
    private func finalizeHLS(at index: Int) throws {
        guard let hls = records[index].hls else { return }
        let id = records[index].id
        let final = "\(id).mp4"
        let destination = Self.directory.appendingPathComponent(final)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: Self.hlsOutputURL(for: id), to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = destination
        try? url.setResourceValues(values)
        try? FileManager.default.removeItem(at: Self.hlsListURL(for: id))
        records[index].fileName = final
        records[index].bytesWritten = hls.bytes
        records[index].expectedBytes = hls.bytes
        records[index].progress = 1
        DownloadDiagnostics.log("\(id): video assembled from \(hls.segmentCount) segments (\(hls.bytes) bytes)")
    }

    private func loadSegmentList(id: String) -> HLSSegmentList? {
        guard let data = try? Data(contentsOf: Self.hlsListURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(HLSSegmentList.self, from: data)
    }

    /// The segment list is gone or broken: start the segmented download over.
    private func resetHLS(at index: Int) {
        let id = records[index].id
        records[index].hls = nil
        try? FileManager.default.removeItem(at: Self.hlsListURL(for: id))
        try? FileManager.default.removeItem(at: Self.hlsOutputURL(for: id))
        records[index].state = .queued
        saveIndex()
        DownloadDiagnostics.log("\(id): segment list missing – requesting it again")
        pump()
    }

    /// Appends a finished segment to the growing video. The file is first cut back to the size after
    /// the previous append, so a segment can never end up in it twice.
    private func appendSegment(_ segment: URL, at index: Int, isInit: Bool) throws {
        guard var hls = records[index].hls else { return }
        let output = Self.hlsOutputURL(for: records[index].id)
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
        records[index].hls = hls
        try? fileManager.removeItem(at: segment)
    }

    // MARK: - Events from the session (main actor)

    private func progressChanged(key: String, task: URLSessionTask, written: Int64, expected: Int64) {
        let (id, part) = DownloadPart.parse(key)
        guard liveTasks[key] === task, let index = records.firstIndex(where: { $0.id == id }) else { return }
        if records[index].errorMessage != nil { records[index].errorMessage = nil }     // data is flowing again
        let total: Int64
        switch part {
        case .extra:
            return                  // extra files: only the "x of y" count is shown
        case .initSegment, .segment:
            guard let hls = records[index].hls else { return }
            inflightBytes[key] = (written, expected)
            let inflight = inflightBytes.filter { DownloadPart.parse($0.key).id == id }.values
            records[index].bytesWritten = hls.bytes + inflight.reduce(0) { $0 + $1.written }
            let fraction = inflight.reduce(0.0) { $0 + ($1.expected > 0 ? Double($1.written) / Double($1.expected) : 0) }
            records[index].progress = min(0.99, (Double(hls.nextSegment) + fraction) / Double(max(hls.segmentCount, 1)))
            total = records[index].expectedBytes ?? 0
        case .original, .playlist:
            records[index].bytesWritten = written
            total = expected > 0 ? expected : (records[index].expectedBytes ?? 0)
            if expected > 0 { records[index].expectedBytes = expected }
            if total > 0 { records[index].progress = min(0.99, Double(written) / Double(total)) }
        }
        let bytes = records[index].bytesWritten
        // A retry that gets real data through starts a fresh count.
        if (records[index].retryCount ?? 0) > 0, bytes - (attemptStartBytes[id] ?? 0) > 2 << 20 {
            records[index].retryCount = 0
        }

        let now = Date.now
        if let sample = speedSamples[id] {
            let elapsed = now.timeIntervalSince(sample.time)
            if elapsed >= 1 {
                let current = Double(max(0, bytes - sample.bytes)) / elapsed
                speeds[id] = speeds[id].map { $0 * 0.6 + current * 0.4 } ?? current
                speedSamples[id] = (now, bytes)
            }
        } else {
            speedSamples[id] = (now, bytes)
        }
        DownloadKeepAlive.progress(completed: bytes, total: total)
        if now.timeIntervalSince(lastIndexSave) > 10 { saveIndex() }
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
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else {
            try? FileManager.default.removeItem(at: file)
            clearTransient(id)
            pump()
            return
        }
        records[index].errorMessage = nil
        records[index].retryAfter = nil

        switch part {
        case .initSegment, .segment:
            if case .segment(let n) = part, let hls = records[index].hls, n != hls.nextSegment {
                // Arrived before the segment in front of it; appended once that one is there.
                guard n > hls.nextSegment else { try? FileManager.default.removeItem(at: file); break }
                break
            }
            do {
                try appendSegment(file, at: index, isInit: part == .initSegment)
                // Segments that arrived early can follow now.
                while let hls = records[index].hls, hls.hasInitSegment, hls.nextSegment < hls.segmentCount,
                      let ready = readySegmentFile(id: id, segment: hls.nextSegment) {
                    try appendSegment(ready, at: index, isInit: false)
                }
            } catch {
                DownloadDiagnostics.log("\(id): couldn't append \(key) – \(DownloadDiagnostics.describe(error as NSError))")
                handleFailure(at: index, part: part, task: task, error: error as NSError, httpStatus: nil)
                return
            }
            if let hls = records[index].hls {
                inflightBytes = inflightBytes.filter { DownloadPart.parse($0.key).id != id || liveTasks[$0.key] != nil }
                records[index].bytesWritten = hls.bytes
                if hls.nextSegment == 1 || hls.nextSegment % 20 == 0 {
                    DownloadDiagnostics.log("\(id): \(hls.nextSegment) of \(hls.segmentCount) segments")
                }
            }
            if records[index].hlsIsComplete {
                do {
                    try finalizeHLS(at: index)
                } catch {
                    handleFailure(at: index, part: part, task: task, error: error as NSError, httpStatus: nil)
                    return
                }
            }
        case .extra(let n):
            if records[index].extras?.indices.contains(n) == true {
                records[index].extras?[n].fileName = fileName
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
            begin(at: index)                         // next part(s); keeps the pipeline full
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
            if case .extra(let n) = part {
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
        if let httpStatus, !Self.isRetryable(status: httpStatus) || (isExtra && httpStatus >= 500 && (records[index].retryCount ?? 0) >= 2) {
            giveUp(Self.message(forStatus: httpStatus))
            return
        }
        if let error, !Self.isRetryable(error), !Self.isStorageError(error) {
            giveUp(error.localizedDescription)
            return
        }
        let attempt = (records[index].retryCount ?? 0) + 1
        guard attempt <= Self.maxRetries else {
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
        records[index].errorMessage = String(localized: "Retrying (\(attempt)/\(Self.maxRetries)): \(reason)")
        downloadLog.notice("Retrying \(id, privacy: .public) in \(delay) s (attempt \(attempt))")
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
    private func refreshEpisodePosters() {
        let pending = records.filter { $0.subtitle != nil && $0.posterSource == nil }.map(\.id)
        guard !pending.isEmpty, let stored = SessionStorage.load() else { return }
        let api = JellyfinAPI(session: stored)
        Task {
            for id in pending {
                guard let item = try? await api.item(id: id) else { continue }
                guard item.type == "Episode" else {
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index].posterSource = "item"; saveIndex() }
                    continue
                }
                await savePoster(from: Self.posterCandidates(for: item, api: api), itemId: id)
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
    var hlsIsComplete: Bool {
        guard let hls else { return false }
        return hls.hasInitSegment && hls.nextSegment >= hls.segmentCount
    }

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
