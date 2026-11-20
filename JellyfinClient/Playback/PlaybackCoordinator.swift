import SwiftUI
import UIKit

/// Starts playback with the player chosen in Settings, reports progress to the server
/// and cleans up (stop report, transcode shutdown) when the player closes.
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()

    private(set) var session: PlaybackSession?
    /// A download playing offline: its progress is kept with the download (and synced later).
    private var localItemId: String?
    private var engine: PlaybackEngine?
    private weak var presentedController: UIViewController?
    /// The player screen while Picture in Picture shows the video (dismissed, but kept for coming back).
    private var parkedController: UIViewController?
    private var progressTask: Task<Void, Never>?
    private var didReportStart = false
    /// Server calls are chained so they arrive in order (Stopped always last).
    private var requestChain: Task<Void, Never>?

    // MARK: - Public


    func play(item: BaseItem, api: JellyfinAPI, maxMbit: Double, startTicks: Int64, selection: TrackSelection) async throws {
        let player = PlayerKind.current
        WatchedStore.shared.forget(item.id, item.seriesId)
        let session = try await PlaybackResolver.resolve(item: item, api: api, maxMbit: maxMbit,
                                                         selection: selection, player: player)
        stop()
        self.session = session
        let subtitle = [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        let metadata = NowPlayingController.Metadata(title: item.name ?? "", subtitle: subtitle.isEmpty ? nil : subtitle,
                                                     artworkURL: api.seriesOrItemPosterURL(for: item, maxWidth: 600))
        present(player: player, url: session.url, title: item.name ?? "",
                startSeconds: Ticks.seconds(startTicks), session: session, metadata: metadata)
    }

    /// Plays with the default streaming quality and the server's default audio/subtitle tracks.
    func playWithDefaults(_ item: BaseItem, api: JellyfinAPI, fromStart: Bool = false) async throws {
        let mbit = UserDefaults.standard.double(forKey: SettingsKeys.streamingMbit)
        try await play(item: item, api: api, maxMbit: mbit, startTicks: fromStart ? 0 : item.resumeTicks,
                       selection: .defaults(for: item.primaryMediaSource))
    }

    /// Extra audio tracks and subtitle files of a download, added to mpv as selectable tracks.
    struct OfflineTrack {
        enum Kind { case audio, subtitle }
        let kind: Kind
        let url: URL
        let title: String
        let language: String?
    }

    func playLocal(fileURL: URL, itemId: String? = nil, startSeconds: Double = 0, title: String, subtitle: String? = nil,
                   posterURL: URL? = nil, tracks: [OfflineTrack] = [], embeddedAudioTitle: String? = nil) {
        stop()
        localItemId = itemId
        present(player: PlayerKind.current, url: fileURL, title: title, startSeconds: startSeconds, session: nil,
                metadata: .init(title: title, subtitle: subtitle, artworkURL: posterURL),
                offlineTracks: tracks, embeddedAudioTitle: embeddedAudioTitle)
    }

    /// Asks the server for a new stream with other tracks or another quality (mpv: track switches that need
    /// a new transcode, and quality changes from the player).
    func reload(selection: TrackSelection, maxMbit: Double? = nil) async throws -> PlaybackSession {
        guard let old = session else { throw APIError.noPlayableSource }
        let new = try await PlaybackResolver.resolve(item: old.item, api: old.api, maxMbit: maxMbit ?? old.maxMbit,
                                                     selection: selection, player: old.player)
        if old.playMethod != .directPlay, let id = old.playSessionId {
            enqueue { try? await old.api.stopTranscoding(playSessionId: id) }
        }
        old.adaptive?.stop()
        session = new
        report(.progress)
        return new
    }

    /// Tears down the current player and tells the server playback ended.
    func stop() {
        guard let engine else { return }
        progressTask?.cancel()
        progressTask = nil
        report(.stopped)
        if let session, session.playMethod != .directPlay, let id = session.playSessionId {
            let api = session.api
            enqueue { try? await api.stopTranscoding(playSessionId: id) }
        }
        engine.teardown()
        NowPlayingController.shared.end()
        session?.adaptive?.stop()
        self.engine = nil
        session = nil
        localItemId = nil
        didReportStart = false
        parkedController = nil
        updateIdleTimer()

        if let controller = presentedController, controller.presentingViewController != nil, !controller.isBeingDismissed {
            controller.dismiss(animated: true)
        }
        presentedController = nil

        // Give the server a moment to store the position before screens reload.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: .playbackDidStop, object: nil)
        }
    }

    // MARK: - Presentation

    private func present(player: PlayerKind, url: URL, title: String, startSeconds: Double, session: PlaybackSession?,
                         metadata: NowPlayingController.Metadata,
                         offlineTracks: [OfflineTrack] = [], embeddedAudioTitle: String? = nil) {
        NotificationCenter.default.post(name: .playbackWillStart, object: nil)
        let controller: UIViewController
        switch player {
        case .native:
            let native = NativePlayerEngine(url: url, startSeconds: startSeconds, session: session)
            native.onReady = { [weak self] in self?.engineDidStart() }
            native.onStateChange = { [weak self] in
                self?.report(.progress)
                self?.updateIdleTimer()
                NowPlayingController.shared.refresh()
            }
            native.onDismiss = { [weak self] in self?.stop() }
            native.onPiPRestore = { [weak self] controller, completion in
                self?.presentAgain(controller, completion: completion) ?? completion(false)
            }
            engine = native
            controller = native.makeViewController()

        case .mpv:
            let mpv = MPVPlayerController(title: title, url: url, startSeconds: startSeconds, session: session,
                                          offlineTracks: offlineTracks, embeddedAudioTitle: embeddedAudioTitle)
            mpv.onReady = { [weak self] in self?.engineDidStart() }
            mpv.onStateChange = { [weak self] in
                self?.report(.progress)
                self?.updateIdleTimer()
                NowPlayingController.shared.refresh()
            }
            mpv.onFinished = { [weak self] in self?.stop() }
            // Unlike Apple's player, the player screen stays up during Picture in Picture (as in Streamyfin):
            // the window shows the layer mpv draws into, which has to stay in the app's window for that.
            mpv.onPiPStarted = { [weak self] in self?.updateIdleTimer() }
            mpv.onPiPRestore = { [weak self] completion in
                guard let self, let parked = self.parkedController else { return completion(true) }
                self.parkedController = nil
                self.presentAgain(parked, completion: completion)
            }
            mpv.onPiPClosed = { [weak self] in self?.stop() }
            mpv.onSelectionChange = { [weak self] selection in
                self?.session?.selection = selection
                self?.report(.progress)
            }
            mpv.reloader = { [weak self] selection, maxMbit in
                guard let self else { throw CancellationError() }
                return try await self.reload(selection: selection, maxMbit: maxMbit)
            }
            engine = mpv
            let host = UIHostingController(rootView: MPVPlayerView(controller: mpv) { [weak self] in self?.stop() })
            host.modalPresentationStyle = .fullScreen
            host.view.backgroundColor = .black
            controller = host
        }
        presentedController = controller
        topViewController()?.present(controller, animated: true)
        if let engine { NowPlayingController.shared.begin(engine: engine, metadata: metadata) }
        updateIdleTimer()
    }

    // MARK: - Screen

    /// Keeps the screen on while a video plays in the player (Auto-Lock, also the short one in Low Power
    /// Mode, would turn it off: mpv doesn't keep it awake by itself). Paused, closed or in Picture in
    /// Picture, the screen may sleep as usual.
    private func updateIdleTimer() {
        let playing = engine.map { !$0.isPausedNow } ?? false
        UIApplication.shared.isIdleTimerDisabled = playing && parkedController == nil
    }

    // MARK: - Picture in Picture

    /// Picture in Picture shows the video: close the player screen (playback goes on) so the app can be used.
    private func parkPlayer() {
        guard let controller = presentedController, controller.presentingViewController != nil else { return }
        parkedController = controller
        controller.dismiss(animated: true)
        updateIdleTimer()
    }

    /// Back from Picture in Picture: show the player screen again.
    private func presentAgain(_ controller: UIViewController, completion: @escaping (Bool) -> Void) {
        guard controller.presentingViewController == nil, let top = topViewController() else { return completion(true) }
        presentedController = controller
        top.present(controller, animated: true) { [weak self] in
            completion(true)
            self?.updateIdleTimer()
        }
    }

    private func engineDidStart() {
        guard !didReportStart else { return }
        didReportStart = true
        report(.start)
        updateIdleTimer()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                self?.report(.progress)
            }
        }
    }

    // MARK: - Reporting

    private func report(_ event: JellyfinAPI.PlaybackEvent) {
        if session == nil, let id = localItemId, let engine, event != .start {
            // Offline: kept with the download, sent to the server when it's reachable.
            DownloadManager.shared.savePlayback(id: id, seconds: engine.currentSeconds, duration: engine.durationSeconds,
                                                syncNow: event == .stopped)
            return
        }
        guard let session, let engine, didReportStart || event == .start else { return }
        if event != .start {
            // Streamed but also downloaded: the download continues from here too.
            DownloadManager.shared.savePlayback(id: session.item.id, seconds: engine.currentSeconds,
                                                duration: engine.durationSeconds, serverKnows: true)
        }
        let report = JellyfinAPI.PlaybackReport(
            itemId: session.item.id,
            mediaSourceId: session.source.id,
            playSessionId: session.playSessionId,
            positionTicks: Ticks.ticks(engine.currentSeconds),
            isPaused: engine.isPausedNow,
            playMethod: session.playMethod.rawValue,
            audioStreamIndex: session.selection.audioIndex,
            subtitleStreamIndex: session.selection.subtitleIndex ?? -1
        )
        let api = session.api
        enqueue { try? await api.reportPlayback(event, report) }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = requestChain
        requestChain = Task {
            await previous?.value
            await work()
        }
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
