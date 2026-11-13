import Foundation
import Observation

struct DownloadRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable { case downloading, completed, failed }

    let id: String              // Jellyfin item id
    var name: String
    var subtitle: String?       // series name + episode label
    var runTimeTicks: Int64?
    var mbit: Double?           // nil = original file
    var fileName: String?
    var posterFileName: String?
    var state: State
    var progress: Double
    var bytesWritten: Int64
    var expectedBytes: Int64?
    var errorMessage: String?
    var createdAt: Date

    var qualityLabel: String {
        mbit.map { Bitrate.label($0) } ?? String(localized: "Original")
    }
}

/// Downloads original or server-transcoded files into Documents/Downloads and keeps an index.
@Observable @MainActor
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    private(set) var records: [DownloadRecord] = []

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300          // transcoding can pause between chunks
        config.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        loadIndex()
        // Downloads don't survive an app restart yet; mark them so the user can retry.
        for index in records.indices where records[index].state == .downloading {
            records[index].state = .failed
            records[index].errorMessage = String(localized: "Interrupted – the app was closed.")
        }
        saveIndex()
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

    // MARK: - Actions

    /// - Parameter mbit: transcode to this bitrate, or `nil` for the original file.
    func start(item: BaseItem, api: JellyfinAPI, mbit: Double?) {
        delete(id: item.id)

        let url = mbit.map { api.transcodedDownloadURL(itemId: item.id, mediaSourceId: item.primaryMediaSource?.id, mbit: $0) }
            ?? api.originalDownloadURL(itemId: item.id)
        var request = URLRequest(url: url)
        request.setValue(api.authorizationHeader, forHTTPHeaderField: "Authorization")

        let subtitle = [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        let expected = mbit.flatMap { Bitrate.estimatedBytes(mbit: $0, runTimeTicks: item.runTimeTicks) }
            ?? item.primaryMediaSource?.size
        records.insert(DownloadRecord(
            id: item.id, name: item.name ?? "Untitled", subtitle: subtitle.isEmpty ? nil : subtitle,
            runTimeTicks: item.runTimeTicks, mbit: mbit, fileName: nil, posterFileName: nil,
            state: .downloading, progress: 0, bytesWritten: 0, expectedBytes: expected,
            errorMessage: nil, createdAt: .now
        ), at: 0)
        saveIndex()

        let task = session.downloadTask(with: request)
        task.taskDescription = item.id
        tasks[item.id] = task
        task.resume()

        if let posterURL = api.posterURL(for: item, maxWidth: 300) {
            Task { await savePoster(from: posterURL, itemId: item.id) }
        }
    }

    /// Cancels a running download or removes a finished one (file included).
    func delete(id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: index)
        for url in [fileURL(for: record), posterURL(for: record)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        saveIndex()
    }

    // MARK: - Internals

    private func update(_ id: String, persist: Bool = false, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        if persist { saveIndex() }
    }

    private func savePoster(from url: URL, itemId: String) async {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let name = "\(itemId)-poster.jpg"
        do {
            try data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
            update(itemId, persist: true) { $0.posterFileName = name }
        } catch {}
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        records = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    fileprivate func progressChanged(id: String, written: Int64, expected: Int64) {
        update(id) { record in
            record.bytesWritten = written
            let total = expected > 0 ? expected : (record.expectedBytes ?? 0)
            if total > 0 { record.progress = min(0.99, Double(written) / Double(total)) }
        }
    }

    fileprivate func finished(id: String, fileName: String, size: Int64) {
        tasks[id] = nil
        update(id, persist: true) { record in
            record.fileName = fileName
            record.bytesWritten = size
            record.progress = 1
            record.state = .completed
        }
    }

    fileprivate func failed(id: String, message: String) {
        tasks[id] = nil
        update(id, persist: true) { record in
            record.state = .failed
            record.errorMessage = message
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in self.progressChanged(id: id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = switch status {
            case 401: String(localized: "Not signed in (HTTP 401).")
            case 403: String(localized: "Your user isn't allowed to download or transcode (HTTP 403).")
            default: String(localized: "Server returned HTTP \(status).")
            }
            Task { @MainActor in self.failed(id: id, message: message) }
            return
        }

        // The file at `location` is deleted when this method returns, so move it synchronously.
        let suggestedExt = (response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        let fileName = "\(id).\(suggestedExt.isEmpty ? "mp4" : suggestedExt.lowercased())"
        let destination = Self.directory.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { @MainActor in self.finished(id: id, fileName: fileName, size: size) }
        } catch {
            Task { @MainActor in self.failed(id: id, message: error.localizedDescription) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in self.failed(id: id, message: error.localizedDescription) }
    }
}
