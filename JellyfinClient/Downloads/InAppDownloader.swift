import Foundation

/// The download engine for installs where iOS' background download service can't hand files to the
/// app (it stores them outside the app's container; seen with re-signed apps that get a random bundle
/// id). Uses a regular URLSession data task and writes straight into `Downloads/.<id>.part`, so no file
/// ever has to be moved out of a system folder. After an interruption it continues from the end of the
/// part file with a Range request (original files); transcoded streams start over.
///
/// It runs inside the app, so the app has to stay running: `BackgroundAudioKeepAlive` keeps it awake in
/// the background while downloads are active.
final class InAppDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Called on the delegate queue; the manager hops to the main actor itself.
    struct Events {
        var progress: (_ id: String, _ task: URLSessionTask, _ written: Int64, _ expected: Int64) -> Void
        var finished: (_ id: String, _ task: URLSessionTask, _ fileName: String, _ size: Int64) -> Void
        var ended: (_ id: String, _ task: URLSessionTask, _ error: NSError?, _ httpStatus: Int?) -> Void
    }

    private struct Transfer {
        let id: String
        var handle: FileHandle?
        var written: Int64 = 0
        var expected: Int64 = -1
        var fileExtension = "mp4"
        var httpStatus: Int?
        var error: NSError?
        var lastReport = Date.distantPast
    }

    var events: Events?
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true                 // wait out short network gaps instead of failing
        config.timeoutIntervalForRequest = 300             // transcoding can pause between chunks
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.urlCache = nil                              // never copy gigabytes into the HTTP cache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "InAppDownloads"
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    static func partURL(for id: String) -> URL {
        DownloadManager.directory.appendingPathComponent(".\(id).part")
    }

    static func partSize(for id: String) -> Int64 {
        let size = (try? partURL(for: id).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }

    /// A data task for the item, continuing an existing part file when `resume` is allowed. Not resumed.
    func makeTask(id: String, request: URLRequest, resume: Bool) -> URLSessionDataTask {
        var request = request
        let existing = Self.partSize(for: id)
        if resume, existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        } else {
            try? FileManager.default.removeItem(at: Self.partURL(for: id))
        }
        let task = session.dataTask(with: request)
        task.taskDescription = id
        lock.withLock { transfers[task.taskIdentifier] = Transfer(id: id) }
        return task
    }

    static func removePart(for id: String) {
        try? FileManager.default.removeItem(at: partURL(for: id))
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let id = dataTask.taskDescription, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let part = Self.partURL(for: id)
        let fileManager = FileManager.default
        var transfer = lock.withLock { transfers[dataTask.taskIdentifier] } ?? Transfer(id: id)
        transfer.httpStatus = http.statusCode

        do {
            switch http.statusCode {
            case 206:
                // Continue where the part file ends; the server must start exactly there.
                let existing = Self.partSize(for: id)
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(existing)-") else {
                    throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
                        NSLocalizedDescriptionKey: "Server resumed at the wrong position (\(range))"])
                }
                let handle = try FileHandle(forWritingTo: part)
                try handle.seekToEnd()
                transfer.handle = handle
                transfer.written = existing
                transfer.expected = http.expectedContentLength > 0 ? existing + http.expectedContentLength : -1
                DownloadDiagnostics.log("\(id): continuing at \(existing) bytes (HTTP 206)")
            case 200..<300:
                try? fileManager.removeItem(at: part)
                try fileManager.createDirectory(at: DownloadManager.directory, withIntermediateDirectories: true)
                guard fileManager.createFile(atPath: part.path, contents: nil, attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                        NSLocalizedDescriptionKey: "Couldn't create \(part.lastPathComponent)"])
                }
                transfer.handle = try FileHandle(forWritingTo: part)
                transfer.written = 0
                transfer.expected = http.expectedContentLength
                DownloadDiagnostics.log("\(id): receiving (HTTP \(http.statusCode), \(http.expectedContentLength) bytes)")
            case 416:
                // The part file doesn't fit the server's file any more; start over.
                try? fileManager.removeItem(at: part)
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
                    NSLocalizedDescriptionKey: "Range not satisfiable; starting over"])
            default:
                lock.withLock { transfers[dataTask.taskIdentifier] = transfer }
                completionHandler(.cancel)          // reported with the status in didCompleteWithError
                return
            }
            if let ext = (http.suggestedFilename as NSString?)?.pathExtension, !ext.isEmpty {
                transfer.fileExtension = ext.lowercased()
            }
            lock.withLock { transfers[dataTask.taskIdentifier] = transfer }
            completionHandler(.allow)
        } catch {
            transfer.error = error as NSError
            transfer.httpStatus = nil
            lock.withLock { transfers[dataTask.taskIdentifier] = transfer }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var transfer = lock.withLock({ transfers[dataTask.taskIdentifier] }), let handle = transfer.handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            transfer.error = error as NSError
            lock.withLock { transfers[dataTask.taskIdentifier] = transfer }
            dataTask.cancel()
            return
        }
        transfer.written += Int64(data.count)
        let now = Date.now
        let report = now.timeIntervalSince(transfer.lastReport) >= 0.5
        if report { transfer.lastReport = now }
        lock.withLock { transfers[dataTask.taskIdentifier] = transfer }
        if report { events?.progress(transfer.id, dataTask, transfer.written, transfer.expected) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? transfer.handle?.synchronize()
        try? transfer.handle?.close()
        let id = transfer.id

        if let failure = transfer.error {
            events?.ended(id, task, failure, nil)
        } else if let status = transfer.httpStatus, !(200..<300).contains(status) {
            events?.ended(id, task, nil, status)
        } else if let error {
            events?.ended(id, task, error as NSError, nil)
        } else {
            // Complete: give the part file its final name.
            let fileName = "\(id).\(transfer.fileExtension)"
            let destination = DownloadManager.directory.appendingPathComponent(fileName)
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: Self.partURL(for: id), to: destination)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var url = destination
                try? url.setResourceValues(values)
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? transfer.written
                events?.finished(id, task, fileName, size)
            } catch {
                events?.ended(id, task, error as NSError, nil)
            }
        }
    }
}
