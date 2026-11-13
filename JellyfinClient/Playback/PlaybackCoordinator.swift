import AVKit
import UIKit

/// Asks the server how to play an item, presents the system player and reports progress back.
///
/// Decision flow: `POST /Items/{id}/PlaybackInfo` with our device profile and the bitrate limit.
/// - Server returns a `TranscodingUrl` → HLS stream (remux or transcode, respecting the limit).
/// - Otherwise the file is natively playable and below the limit → direct play of the static file.
@MainActor
final class PlaybackCoordinator: NSObject, AVPlayerViewControllerDelegate {
    static let shared = PlaybackCoordinator()

    private struct RemoteContext {
        let api: JellyfinAPI
        let itemId: String
        let mediaSourceId: String?
        let playSessionId: String?
        let playMethod: String
    }

    private var player: AVPlayer?
    private var remote: RemoteContext?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var didReportStart = false
    /// Reports are chained so the server always receives them in order (Stopped last).
    private var reportChain: Task<Void, Never>?

    // MARK: - Public

    func playRemote(item: BaseItem, api: JellyfinAPI, maxMbit: Double, startTicks: Int64) async throws {
        let info = try await api.playbackInfo(itemId: item.id, maxBitrate: Bitrate.bps(forMbit: maxMbit))
        if let code = info.errorCode { throw APIError.playback(code: code) }
        guard let source = info.mediaSources?.first else { throw APIError.noPlayableSource }

        let url: URL
        let method: String
        if let transcodingPath = source.transcodingUrl, let resolved = api.absoluteURL(serverRelative: transcodingPath) {
            url = Self.adjustTranscodingURL(resolved, api: api, source: source, maxMbit: maxMbit)
            method = transcodingPath.localizedCaseInsensitiveContains("videocodec=copy") ? "DirectStream" : "Transcode"
        } else if source.supportsDirectPlay == true || source.supportsDirectStream == true {
            url = api.directStreamURL(itemId: item.id, mediaSourceId: source.id,
                                      container: source.container, playSessionId: info.playSessionId)
            method = "DirectPlay"
        } else {
            throw APIError.noPlayableSource
        }

        #if DEBUG
        print("[Playback] \(method) → \(url.absoluteString.replacingOccurrences(of: api.accessToken ?? "-", with: "<token>"))")
        #endif

        let context = RemoteContext(api: api, itemId: item.id, mediaSourceId: source.id,
                                    playSessionId: info.playSessionId, playMethod: method)
        present(url: url, startSeconds: Ticks.seconds(startTicks), remote: context)
    }

    func playLocal(fileURL: URL) {
        present(url: fileURL, startSeconds: 0, remote: nil)
    }

    // MARK: - Presentation

    private func present(url: URL, startSeconds: Double, remote: RemoteContext?) {
        stop()

        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        self.remote = remote
        didReportStart = false

        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.modalPresentationStyle = .fullScreen

        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item, startSeconds: startSeconds) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.report(.progress) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(.progress) }
        }

        topViewController()?.present(controller, animated: true)
    }

    private func itemStatusChanged(_ item: AVPlayerItem, startSeconds: Double) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .readyToPlay where !didReportStart:
            didReportStart = true
            if startSeconds > 1 {
                player?.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in self?.player?.play() }
                }
            } else {
                player?.play()
            }
            report(.start)
        case .failed:
            #if DEBUG
            print("[Playback] failed: \(item.error?.localizedDescription ?? "unknown")")
            #endif
        default:
            break
        }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        MainActor.assumeIsolated {
            _ = coordinator.animate(alongsideTransition: nil) { context in
                guard !context.isCancelled else { return }
                Task { @MainActor in PlaybackCoordinator.shared.stop() }
            }
        }
    }

    /// Tears down the current player and tells the server playback ended.
    func stop() {
        guard let player else { return }
        // Detach observers first so pausing below can't trigger another progress report.
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        rateObservation = nil
        report(.stopped)
        if let remote, remote.playMethod != "DirectPlay", let session = remote.playSessionId {
            let api = remote.api
            let previous = reportChain
            reportChain = Task {
                await previous?.value
                try? await api.stopTranscoding(playSessionId: session)
            }
        }
        player.pause()
        self.player = nil
        self.remote = nil

        // Give the server a moment to store the position before screens reload.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: .playbackDidStop, object: nil)
        }
    }

    // MARK: - Reporting

    private func report(_ event: JellyfinAPI.PlaybackEvent) {
        guard let remote, let player, didReportStart || event == .start else { return }
        let report = JellyfinAPI.PlaybackReport(
            itemId: remote.itemId,
            mediaSourceId: remote.mediaSourceId,
            playSessionId: remote.playSessionId,
            positionTicks: Ticks.ticks(player.currentTime().seconds),
            isPaused: player.timeControlStatus == .paused,
            playMethod: remote.playMethod
        )
        let api = remote.api
        let previous = reportChain
        reportChain = Task {
            await previous?.value
            try? await api.reportPlayback(event, report)
        }
    }

    // MARK: - Helpers

    /// Makes sure the HLS URL carries the token and, when we're limiting bitrate, a sensible resolution cap.
    private static func adjustTranscodingURL(_ url: URL, api: JellyfinAPI, source: MediaSourceInfo, maxMbit: Double) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        let names = Set(items.map { $0.name.lowercased() })
        if !names.contains("api_key") && !names.contains("apikey"), let token = api.accessToken {
            items.append(URLQueryItem(name: "api_key", value: token))
        }
        let sourceIsAboveLimit = maxMbit > 0 && (source.bitrate ?? .max) > Bitrate.bps(forMbit: maxMbit)
        if sourceIsAboveLimit, !names.contains("maxwidth"), let width = Bitrate.maxWidth(forMbit: maxMbit) {
            items.append(URLQueryItem(name: "maxWidth", value: String(width)))
        }
        comps.queryItems = items
        return comps.url ?? url
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
