import SwiftUI
import UIKit

/// Loads, decodes and caches artwork.
///
/// Replaces `AsyncImage`, which drops a load for good when its view is refreshed mid-download
/// (common on the home screen while rows reload) and never retries after a slow or failed request.
/// Here every URL is downloaded once, the download finishes even if the view that asked for it
/// went away, failures are retried, and decoded images stay in memory for instant reuse.
actor ImagePipeline {
    static let shared = ImagePipeline()

    /// NSCache is thread-safe, so it can be read without hopping onto the actor.
    private final class MemoryCache: @unchecked Sendable {
        private let cache: NSCache<NSURL, UIImage> = {
            let cache = NSCache<NSURL, UIImage>()
            cache.totalCostLimit = 200 * 1024 * 1024
            return cache
        }()
        func object(forKey url: NSURL) -> UIImage? { cache.object(forKey: url) }
        func setObject(_ image: UIImage, forKey url: NSURL, cost: Int) { cache.setObject(image, forKey: url, cost: cost) }
    }

    private nonisolated let memory = MemoryCache()
    private var inFlight: [URL: Task<UIImage, Error>] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    enum ImageError: Error { case badResponse(Int), undecodable }

    /// Synchronous lookup so views can show cached images on their first frame.
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async throws -> UIImage {
        if let cached = cachedImage(for: url) { return cached }
        if let running = inFlight[url] { return try await running.value }

        // Not tied to the caller: if the view disappears, the image still finishes and lands in the cache.
        let task = Task<UIImage, Error> { try await Self.download(url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }

        let image = try await task.value
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    private static func download(_ url: URL, attempts: Int = 4) async throws -> UIImage {
        var lastError: Error = ImageError.undecodable
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if status == 404 { throw ImageError.badResponse(status) }          // won't appear by retrying
                guard (200..<300).contains(status) else { throw RetryableError.status(status) }
                guard let image = UIImage(data: data) else { throw ImageError.undecodable }
                return await image.byPreparingForDisplay() ?? image
            } catch let error as ImageError {
                throw error
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    try? await Task.sleep(for: .milliseconds(400 * (1 << attempt)))   // 0.4 s, 0.8 s, 1.6 s
                }
            }
        }
        throw lastError
    }

    private enum RetryableError: Error { case status(Int) }
}

/// Shows an image from the pipeline: cached images appear immediately, others fade in once loaded.
struct PipelineImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: (_ failed: Bool) -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping (_ failed: Bool) -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cachedImage(for: $0) })
    }

    var body: some View {
        ZStack {
            if let image {
                content(Image(uiImage: image))
                    .transition(.opacity)
            } else {
                placeholder(failed || url == nil)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        if let cached = ImagePipeline.shared.cachedImage(for: url) {
            image = cached
            return
        }
        image = nil
        failed = false
        // Each pipeline call already retries quickly; if the server is still struggling, keep trying
        // a little later while the view is on screen instead of giving up for good.
        for pause in [Duration.zero, .seconds(3), .seconds(10), .seconds(30)] {
            if pause > .zero {
                try? await Task.sleep(for: pause)
                guard !Task.isCancelled else { return }
            }
            do {
                let loaded = try await ImagePipeline.shared.image(for: url)
                withAnimation(.easeIn(duration: 0.2)) { image = loaded }
                return
            } catch is ImagePipeline.ImageError {
                break                       // 404 or not an image: retrying won't help
            } catch {
                continue
            }
        }
        failed = true
    }
}
