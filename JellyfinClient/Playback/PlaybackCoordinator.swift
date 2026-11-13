import SwiftUI
import UIKit

/// Starts playback with the player chosen in Settings, reports progress to the server
/// and cleans up (stop report, transcode shutdown) when the player closes.
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()

    private(set) var session: PlaybackSession?
    private var engine: PlaybackEngine?
    private weak var presentedController: UIViewController?
    private var progressTask: Task<Void, Never>?
    private var didReportStart = false
    /// Server calls are chained so they arrive in order (Stopped always last).
    private var requestChain: Task<Void, Never>?

    // MARK: - Public

    func play(item: BaseItem, api: JellyfinAPI, maxMbit: Double, startTicks: Int64, selection: TrackSelection) async throws {
        let player = PlayerKind.current
        let session = try await PlaybackResolver.resolve(item: item, api: api, maxMbit: maxMbit,
                                                         selection: selection, player: player)
        stop()
        self.session = session
        present(player: player, url: session.url, title: item.name ?? "",
                startSeconds: Ticks.seconds(startTicks), session: session)
    }

    /// Plays with the default streaming quality and the server's default audio/subtitle tracks.
    func playWithDefaults(_ item: BaseItem, api: JellyfinAPI, fromStart: Bool = false) async throws {
        let mbit = UserDefaults.standard.double(forKey: SettingsKeys.streamingMbit)
        try await play(item: item, api: api, maxMbit: mbit, startTicks: fromStart ? 0 : item.resumeTicks,
                       selection: .defaults(for: item.primaryMediaSource))
    }

    func playLocal(fileURL: URL, title: String) {
        stop()
        present(player: PlayerKind.current, url: fileURL, title: title, startSeconds: 0, session: nil)
    }

    /// Asks the server for a new stream with other tracks (used by mpv when a switch needs a new transcode).
    func reload(selection: TrackSelection) async throws -> PlaybackSession {
        guard let old = session else { throw APIError.noPlayableSource }
        let new = try await PlaybackResolver.resolve(item: old.item, api: old.api, maxMbit: old.maxMbit,
                                                     selection: selection, player: old.player)
        if old.playMethod != .directPlay, let id = old.playSessionId {
            enqueue { try? await old.api.stopTranscoding(playSessionId: id) }
        }
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
        self.engine = nil
        session = nil
        didReportStart = false

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

    private func present(player: PlayerKind, url: URL, title: String, startSeconds: Double, session: PlaybackSession?) {
        NotificationCenter.default.post(name: .playbackWillStart, object: nil)
        let controller: UIViewController
        switch player {
        case .native:
            let native = NativePlayerEngine(url: url, startSeconds: startSeconds, session: session)
            native.onReady = { [weak self] in self?.engineDidStart() }
            native.onStateChange = { [weak self] in self?.report(.progress) }
            native.onDismiss = { [weak self] in self?.stop() }
            engine = native
            controller = native.makeViewController()

        case .mpv:
            let mpv = MPVPlayerController(title: title, url: url, startSeconds: startSeconds, session: session)
            mpv.onReady = { [weak self] in self?.engineDidStart() }
            mpv.onStateChange = { [weak self] in self?.report(.progress) }
            mpv.onFinished = { [weak self] in self?.stop() }
            mpv.onSelectionChange = { [weak self] selection in
                self?.session?.selection = selection
                self?.report(.progress)
            }
            mpv.reloader = { [weak self] selection in
                guard let self else { throw CancellationError() }
                return try await self.reload(selection: selection)
            }
            engine = mpv
            let host = UIHostingController(rootView: MPVPlayerView(controller: mpv) { [weak self] in self?.stop() })
            host.modalPresentationStyle = .fullScreen
            host.view.backgroundColor = .black
            controller = host
        }
        presentedController = controller
        topViewController()?.present(controller, animated: true)
    }

    private func engineDidStart() {
        guard !didReportStart else { return }
        didReportStart = true
        report(.start)
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
        guard let session, let engine, didReportStart || event == .start else { return }
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
