import Foundation
import Observation
import UIKit
import UserNotifications
import os

let downloadLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JellyfinClient", category: "Downloads")

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

    var qualityLabel: String {
        mbit.map { Bitrate.label($0) } ?? String(localized: "Original")
    }

    /// Queued or transferring: the manager still owns it.
    var isActive: Bool { state == .queued || state == .downloading }
}

/// Downloads original or server-transcoded files into Documents/Downloads, built like Streamyfin's
/// native downloader:
///
/// - The transfer runs in a **background URLSession**, so it is carried out by the system's download
///   daemon, not the app. Leaving the app, locking the screen or the app being suspended or killed by
///   iOS doesn't stop it; iOS relaunches the app in the background when it finishes.
/// - The task's `taskDescription` (the item id) and the index on disk survive a relaunch, so a
///   download that finished while the app was gone is still moved into place.
/// - Downloads run **one at a time** from a persisted queue, like Streamyfin, so a season doesn't
///   start a dozen transcodes on the server at once.
/// - On iOS 26 a continued-processing task keeps the app running while the queue drains, so the next
///   episode starts right away even in the background.
///
/// On top of that, interrupted transfers are retried automatically and resume where they stopped
/// when the server allows it (original files), instead of failing.
@Observable @MainActor
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    nonisolated static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "JellyfinClient") + ".downloads"
    private static let maxConcurrent = 1
    private static let maxRetries = 10

    private(set) var records: [DownloadRecord] = []
    /// Current transfer speed in bytes per second, by item id.
    private(set) var speeds: [String: Double] = [:]

    /// Handed over by the app delegate when iOS wakes the app for this session; called once all
    /// pending events are delivered.
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var liveTasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var isReconnected = false
    /// The index exists but can't be read yet (woken while the iPhone is locked and the file is still
    /// under complete protection). Nothing is saved or deleted until it can be read.
    @ObservationIgnored private var indexUnavailable = false
    /// Transfers finished while the index was unreadable; filed once it can be read.
    @ObservationIgnored private var pendingCompletions: [(id: String, fileName: String, size: Int64)] = []
    /// Finished files that couldn't be moved into the locked download folder yet.
    @ObservationIgnored private var parkedFiles: [String: (url: URL, fileName: String, size: Int64)] = [:]
    @ObservationIgnored private var eventsDelivered = false
    @ObservationIgnored private var speedSamples: [String: (time: Date, bytes: Int64)] = [:]
    @ObservationIgnored private var attemptStartBytes: [String: Int64] = [:]
    @ObservationIgnored private var lastIndexSave = Date.distantPast

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    nonisolated private static func resumeDataURL(for id: String) -> URL {
        directory.appendingPathComponent(".\(id).resume")
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

        session.getAllTasks { tasks in
            let downloads = tasks.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor in self.reconnect(downloads) }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(protectedDataAvailable),
            name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    }

    /// Sideloading tools often sign with the provisioning profile's default data protection
    /// ("complete"), which locks the app's files whenever the iPhone is locked, so a download that
    /// finishes with the screen off couldn't be moved into place. The download folder and its files
    /// use "until first unlock" instead (iOS' normal default), so they stay writable while locked.
    /// Changing the class of existing files only works while unlocked, so this runs again on unlock.
    ///
    /// The same goes for the folder the system's download service writes the transfer into while it
    /// runs (`Library/Caches/com.apple.nsurlsessiond/Downloads/<bundle id>`): under "complete" it
    /// can't create the file while the iPhone is locked ("The file can't be created").
    nonisolated private static func prepareDirectory() {
        let fileManager = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let serviceRoot = caches.appendingPathComponent("com.apple.nsurlsessiond", isDirectory: true)
        let serviceDownloads = serviceRoot.appendingPathComponent("Downloads", isDirectory: true)
        let serviceApp = serviceDownloads.appendingPathComponent(Bundle.main.bundleIdentifier ?? "JellyfinClient", isDirectory: true)

        for folder in [directory, serviceApp] {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: protection)
        }
        // New files take the class of their folder, so the folders matter most.
        for folder in [library, caches, documents, fileManager.temporaryDirectory, serviceRoot, serviceDownloads, serviceApp, directory] {
            try? fileManager.setAttributes(protection, ofItemAtPath: folder.path)
        }
        // Existing files: the finished downloads and index, and transfers in progress.
        for folder in [directory, serviceApp] {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try? fileManager.setAttributes(protection, ofItemAtPath: folder.appendingPathComponent(name).path)
            }
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

    // MARK: - Actions

    /// Adds the item to the download queue.
    /// - Parameter mbit: transcode to this bitrate, or `nil` for the original file.
    func start(item: BaseItem, api: JellyfinAPI, mbit: Double?) {
        delete(id: item.id)

        let subtitle = [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        let expected = mbit.flatMap { Bitrate.estimatedBytes(mbit: $0, runTimeTicks: item.runTimeTicks) }
            ?? item.primaryMediaSource?.size
        records.insert(DownloadRecord(
            id: item.id, name: item.name ?? "Untitled", subtitle: subtitle.isEmpty ? nil : subtitle,
            runTimeTicks: item.runTimeTicks, mbit: mbit, mediaSourceId: item.primaryMediaSource?.id,
            fileName: nil, posterFileName: nil, state: .queued, progress: 0, bytesWritten: 0,
            expectedBytes: expected, errorMessage: nil, createdAt: .now
        ), at: 0)
        saveIndex()

        if let posterURL = api.posterURL(for: item, maxWidth: 300) {
            Task { await savePoster(from: posterURL, itemId: item.id) }
        }
        DownloadNotifications.requestAuthorizationIfNeeded()
        // Started from the foreground: the only moment iOS lets us ask to keep running afterwards.
        DownloadKeepAlive.begin(title: String(localized: "Downloading"), subtitle: item.name ?? "")
        pump()
    }

    /// Tries a failed download again, picking up where it stopped when possible.
    func retry(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .failed else { return }
        records[index].state = .queued
        records[index].errorMessage = nil
        records[index].retryCount = 0
        records[index].retryAfter = nil
        saveIndex()
        DownloadKeepAlive.begin(title: String(localized: "Downloading"), subtitle: records[index].name)
        pump()
    }

    /// Cancels a running or queued download or removes a finished one (file included).
    func delete(id: String) {
        liveTasks.removeValue(forKey: id)?.cancel()
        try? FileManager.default.removeItem(at: Self.resumeDataURL(for: id))
        speeds[id] = nil
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: index)
        for url in [fileURL(for: record), posterURL(for: record)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        saveIndex()
        pump()
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
            guard let id = task.taskDescription,
                  let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else {
                task.cancel()           // deleted while the app was gone
                continue
            }
            liveTasks[id] = task
            records[index].state = .downloading
            attemptStartBytes[id] = task.countOfBytesReceived
        }
        downloadLog.notice("Reconnected \(self.liveTasks.count) running download(s)")

        // Marked as downloading, but the system has no transfer for it: either it finished while the
        // app was gone (its completion arrives in a moment) or it was lost. Requeue it; if the
        // completion still shows up, it wins.
        for index in records.indices where records[index].state == .downloading && liveTasks[records[index].id] == nil {
            records[index].state = .queued
            records[index].retryAfter = .now.addingTimeInterval(3)
        }
        saveIndex()
        isReconnected = true
        pump()
        if eventsDelivered { callBackgroundCompletion() }
    }

    /// Starts queued downloads while there is room: interrupted ones first, then the oldest.
    private func pump() {
        guard isReconnected else { return }
        while records.filter({ $0.state == .downloading }).count < Self.maxConcurrent,
              let index = records.lastIndex(where: { $0.state == .queued && ($0.retryCount ?? 0) > 0 })
                ?? records.lastIndex(where: { $0.state == .queued }) {
            begin(at: index)
        }
        if !hasActiveDownloads { DownloadKeepAlive.end() }
    }

    private func begin(at index: Int) {
        let record = records[index]
        let id = record.id
        let task: URLSessionDownloadTask

        if let resumeData = try? Data(contentsOf: Self.resumeDataURL(for: id)) {
            // Picks up the bytes already on disk instead of starting over.
            task = session.downloadTask(withResumeData: resumeData)
            try? FileManager.default.removeItem(at: Self.resumeDataURL(for: id))
            downloadLog.notice("Resuming \(id, privacy: .public)")
        } else {
            // The token comes from the Keychain (readable after first unlock), so this also works when
            // the app was relaunched in the background with the screen locked.
            guard let session = SessionStorage.load() else {
                fail(at: index, message: String(localized: "Not signed in."))
                return
            }
            let api = JellyfinAPI(session: session)
            let url = record.mbit.map {
                api.transcodedDownloadURL(itemId: id, mediaSourceId: record.mediaSourceId, mbit: $0)
            } ?? api.originalDownloadURL(itemId: id)
            var request = URLRequest(url: url)
            request.setValue(api.authorizationHeader, forHTTPHeaderField: "Authorization")
            task = self.session.downloadTask(with: request)
            records[index].bytesWritten = 0
            records[index].progress = 0
            downloadLog.notice("Starting \(id, privacy: .public)")
        }

        task.taskDescription = id
        // A retry waits out its backoff inside the system's download service, so it still happens
        // when the app is suspended in the background.
        if let retryAfter = record.retryAfter, retryAfter > .now {
            task.earliestBeginDate = retryAfter
        }
        if let expected = record.expectedBytes, expected > 0 {
            task.countOfBytesClientExpectsToReceive = expected
        }
        liveTasks[id] = task
        attemptStartBytes[id] = records[index].bytesWritten
        records[index].state = .downloading
        records[index].retryAfter = nil
        saveIndex()
        task.resume()
        DownloadKeepAlive.update(title: String(localized: "Downloading"), subtitle: record.name)
    }

    @objc private func appDidBecomeActive() {
        Self.prepareDirectory()
        retryDeferredIndex()
        fileParkedDownloads()
        pump()
    }

    @objc private func protectedDataAvailable() {
        Self.prepareDirectory()
        retryDeferredIndex()
        fileParkedDownloads()
    }

    /// A transfer finished, but the download folder was locked; the file waits next to the system's
    /// temporary copy until the iPhone is unlocked.
    private func parked(id: String, task: URLSessionDownloadTask, url: URL, fileName: String, size: Int64) {
        parkedFiles[id] = (url, fileName, size)
        if !indexUnavailable, let index = records.firstIndex(where: { $0.id == id }) {
            records[index].errorMessage = String(localized: "Finished – saved when you unlock your iPhone")
            records[index].progress = 1
        }
        if UIApplication.shared.isProtectedDataAvailable { fileParkedDownloads() }
    }

    private func fileParkedDownloads() {
        guard !indexUnavailable, !parkedFiles.isEmpty else { return }
        for (id, file) in parkedFiles {
            let destination = Self.directory.appendingPathComponent(file.fileName)
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file.url, to: destination)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                parkedFiles[id] = nil
                finished(id: id, task: liveTasks[id], fileName: file.fileName, size: file.size)
            } catch {
                downloadLog.error("Still can't file \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Unlocked and still failing: a real error, not data protection.
                if UIApplication.shared.isProtectedDataAvailable {
                    parkedFiles[id] = nil
                    try? FileManager.default.removeItem(at: file.url)
                    liveTasks[id] = nil
                    if let index = records.firstIndex(where: { $0.id == id }) {
                        fail(at: index, message: error.localizedDescription)
                    }
                    pump()
                }
            }
        }
    }

    /// The iPhone was unlocked: read the index now, file what finished meanwhile and reconnect.
    private func retryDeferredIndex() {
        guard indexUnavailable else { return }
        loadIndex()
        guard !indexUnavailable else { return }
        downloadLog.notice("Index readable again; filing \(self.pendingCompletions.count) finished download(s)")
        let pending = pendingCompletions
        pendingCompletions = []
        for item in pending { finished(id: item.id, task: nil, fileName: item.fileName, size: item.size) }
        session.getAllTasks { tasks in
            let downloads = tasks.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor in self.reconnect(downloads) }
        }
    }

    // MARK: - Events from the session (main actor)

    private func progressChanged(id: String, task: URLSessionDownloadTask, written: Int64, expected: Int64) {
        guard liveTasks[id] === task, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].bytesWritten = written
        if records[index].errorMessage != nil { records[index].errorMessage = nil }     // data is flowing again
        let total = expected > 0 ? expected : (records[index].expectedBytes ?? 0)
        if expected > 0 { records[index].expectedBytes = expected }
        if total > 0 { records[index].progress = min(0.99, Double(written) / Double(total)) }
        // A retry that gets real data through starts a fresh count.
        if (records[index].retryCount ?? 0) > 0, written - (attemptStartBytes[id] ?? 0) > 8 << 20 {
            records[index].retryCount = 0
        }

        let now = Date.now
        if let sample = speedSamples[id] {
            let elapsed = now.timeIntervalSince(sample.time)
            if elapsed >= 1 {
                let current = Double(written - sample.bytes) / elapsed
                speeds[id] = speeds[id].map { $0 * 0.6 + current * 0.4 } ?? current
                speedSamples[id] = (now, written)
            }
        } else {
            speedSamples[id] = (now, written)
        }
        DownloadKeepAlive.progress(completed: written, total: total)
        if now.timeIntervalSince(lastIndexSave) > 10 { saveIndex() }
    }

    private func finished(id: String, task: URLSessionDownloadTask?, fileName: String, size: Int64) {
        if indexUnavailable {
            pendingCompletions.append((id, fileName, size))     // keep the file; filed after unlock
            return
        }
        if let current = liveTasks[id], current !== task { current.cancel() }   // a duplicate restart lost the race
        liveTasks[id] = nil
        clearTransient(id)
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(fileName))
            pump()
            return
        }
        records[index].fileName = fileName
        records[index].bytesWritten = size
        records[index].expectedBytes = size
        records[index].progress = 1
        records[index].state = .completed
        records[index].errorMessage = nil
        records[index].retryCount = nil
        records[index].retryAfter = nil
        saveIndex()
        downloadLog.notice("Finished \(id, privacy: .public)")
        DownloadNotifications.post(title: String(localized: "Download Complete"), body: records[index].name, id: id)
        pump()
    }

    /// The transfer ended without a file (network error, server error, cancellation).
    private func ended(id: String, task: URLSessionTask, error: NSError?, httpStatus: Int?) {
        if indexUnavailable {
            // Keep the partial data; after unlock the download is requeued and resumes from it.
            if let resumeData = error?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resumeData.write(to: Self.resumeDataURL(for: id), options: .atomic)
            }
            return
        }
        if let current = liveTasks[id], current !== task { return }     // an older attempt; ignore
        liveTasks[id] = nil
        clearTransient(id)
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive else {
            try? FileManager.default.removeItem(at: Self.resumeDataURL(for: id))
            pump()
            return
        }
        // Keep what was transferred so the next attempt continues from there.
        if let resumeData = error?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: Self.resumeDataURL(for: id), options: .atomic)
        }

        if let error, Self.isStorageError(error), !UIApplication.shared.isProtectedDataAvailable {
            // The iPhone is locked and its storage isn't writable for this download right now. Not a
            // real failure: try again in a minute (inside the download service, so this also happens
            // while the app is suspended) without using up the retry budget.
            records[index].state = .queued
            records[index].retryAfter = .now.addingTimeInterval(60)
            records[index].errorMessage = String(localized: "iPhone locked – trying again shortly")
            downloadLog.notice("Storage locked for \(id, privacy: .public); retrying in 60 s")
            saveIndex()
        } else if let httpStatus, !Self.isRetryable(status: httpStatus) {
            fail(at: index, message: Self.message(forStatus: httpStatus))
        } else if let error, !Self.isRetryable(error), !Self.isStorageError(error) {
            fail(at: index, message: error.localizedDescription)
        } else {
            let attempt = (records[index].retryCount ?? 0) + 1
            if attempt > Self.maxRetries {
                fail(at: index, message: httpStatus.map(Self.message(forStatus:))
                     ?? error?.localizedDescription ?? String(localized: "Download failed."))
            } else {
                // Force quit, network loss, server hiccup: wait a bit, then try again. The wait happens
                // in the download service (earliestBeginDate), so it also works while suspended.
                let wasCancelledBySystem = error?.code == NSURLErrorCancelled
                let delay = wasCancelledBySystem ? 0 : min(60, pow(2, Double(attempt - 1)))
                records[index].retryCount = attempt
                records[index].state = .queued
                records[index].retryAfter = delay > 0 ? .now.addingTimeInterval(delay) : nil
                records[index].errorMessage = String(localized: "Connection interrupted – retrying (\(attempt)/\(Self.maxRetries))")
                downloadLog.notice("Retrying \(id, privacy: .public) in \(delay) s (attempt \(attempt))")
                saveIndex()
            }
        }
        pump()
    }

    private func fail(at index: Int, message: String) {
        let id = records[index].id
        records[index].state = .failed
        records[index].errorMessage = message
        records[index].retryAfter = nil
        try? FileManager.default.removeItem(at: Self.resumeDataURL(for: id))
        saveIndex()
        downloadLog.error("Failed \(id, privacy: .public): \(message, privacy: .public)")
        DownloadNotifications.post(title: String(localized: "Download Failed"),
                                   body: "\(records[index].name) – \(message)", id: id)
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

    private func savePoster(from url: URL, itemId: String) async {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let name = "\(itemId)-poster.jpg"
        do {
            try data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
            guard let index = records.firstIndex(where: { $0.id == itemId }) else { return }
            records[index].posterFileName = name
            saveIndex()
        } catch {}
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

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            self.progressChanged(id: id, task: downloadTask, written: totalBytesWritten,
                                 expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        // A 4xx/5xx still "finishes" — the file is the server's error page, not the video.
        guard (200..<300).contains(status) else {
            Task { @MainActor in self.ended(id: id, task: downloadTask, error: nil, httpStatus: status) }
            return
        }

        // The file at `location` is deleted when this method returns, so move it synchronously.
        let suggestedExt = (response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        let fileName = "\(id).\(suggestedExt.isEmpty ? "mp4" : suggestedExt.lowercased())"
        let destination = Self.directory.appendingPathComponent(fileName)
        do {
            Self.prepareDirectory()
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                // Folder still locked (old protection class, device locked): park the file in the
                // download service's own temp area, which is writable now, and file it on unlock.
                let parked = location.deletingLastPathComponent().appendingPathComponent("parked-\(fileName)")
                try? FileManager.default.removeItem(at: parked)
                try FileManager.default.moveItem(at: location, to: parked)
                let size = (try? parked.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                downloadLog.notice("Parked \(id, privacy: .public) until the iPhone is unlocked")
                Task { @MainActor in self.parked(id: id, task: downloadTask, url: parked, fileName: fileName, size: size) }
                return
            }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true      // large and re-downloadable; keep it out of iCloud backups
            var url = destination
            try? url.setResourceValues(values)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { @MainActor in self.finished(id: id, task: downloadTask, fileName: fileName, size: size) }
        } catch {
            let nsError = error as NSError
            Task { @MainActor in self.ended(id: id, task: downloadTask, error: nsError, httpStatus: nil) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is handled in didFinishDownloadingTo.
        guard let error, let id = task.taskDescription else { return }
        let nsError = error as NSError
        downloadLog.notice("Task for \(id, privacy: .public) ended: \(nsError.domain, privacy: .public) \(nsError.code)")
        Task { @MainActor in self.ended(id: id, task: task, error: nsError, httpStatus: nil) }
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
