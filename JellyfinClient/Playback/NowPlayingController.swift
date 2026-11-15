import AVFoundation
import MediaPlayer
import UIKit

/// The mini player on the Lock Screen, in Control Center and on paired devices: title, series and
/// episode, poster, progress, play/pause, ±10 s and scrubbing – for mpv and Apple's player alike.
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    private weak var engine: PlaybackEngine?
    private var info: [String: Any] = [:]
    private var commandsInstalled = false
    private var updater: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?

    struct Metadata {
        var title: String
        var subtitle: String?
        /// Remote poster or a downloaded file.
        var artworkURL: URL?
    }

    /// Shows the mini player for a playback that just started.
    func begin(engine: PlaybackEngine, metadata: Metadata) {
        self.engine = engine
        try? AVAudioSession.sharedInstance().setActive(true)
        installCommandsIfNeeded()
        setCommands(enabled: true)

        info = [
            MPMediaItemPropertyTitle: metadata.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let subtitle = metadata.subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        refresh()
        loadArtwork(metadata.artworkURL)

        // Position and rate let iOS run the progress bar by itself; this only corrects drift and seeks.
        updater?.cancel()
        updater = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    /// Updates position, duration and play state (after play/pause, seeking, a new duration).
    func refresh() {
        guard let engine else { return }
        let duration = engine.durationSeconds
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentSeconds
        let rate: Double = engine.isPausedNow ? 0 : 1
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = engine.isPausedNow ? .paused : .playing
    }

    /// Removes the mini player when playback ends.
    func end() {
        updater?.cancel()
        updater = nil
        artworkTask?.cancel()
        artworkTask = nil
        engine = nil
        info = [:]
        setCommands(enabled: false)
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    // MARK: - Private

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            guard !Task.isCancelled, let data, let image = UIImage(data: data), let self, self.engine != nil else { return }
            self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.refresh()
        }
    }

    private func installCommandsIfNeeded() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in self?.perform { $0.play() } ?? .noActionableNowPlayingItem }
        center.pauseCommand.addTarget { [weak self] _ in self?.perform { $0.pause() } ?? .noActionableNowPlayingItem }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.perform { $0.isPausedNow ? $0.play() : $0.pause() } ?? .noActionableNowPlayingItem
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.perform { $0.skip(by: 10) } ?? .noActionableNowPlayingItem }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.perform { $0.skip(by: -10) } ?? .noActionableNowPlayingItem }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.perform { $0.seek(to: event.positionTime) } ?? .noActionableNowPlayingItem
        }
        // Not a playlist: no next/previous.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func setCommands(enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            command.isEnabled = enabled
        }
    }

    /// Runs a remote command on the current player (remote commands arrive on the main thread).
    private nonisolated func perform(_ action: @escaping @MainActor (PlaybackEngine) -> Void) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard let engine else { return .noActionableNowPlayingItem }
            action(engine)
            // Seeks take a moment: refresh right away (rate) and once they're done (position).
            refresh()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.refresh()
            }
            return .success
        }
    }
}
