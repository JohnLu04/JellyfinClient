import AVKit
import UIKit

/// Picture in Picture for mpv.
///
/// mpv draws with Vulkan/Metal straight into its layer; iOS' Picture in Picture only takes an
/// AVPlayerLayer or sample buffers, and apps in the background may not use the GPU at all. So for
/// Picture in Picture the playback is handed over to an AVPlayer at the same position (the same file
/// offline, or a stream the server prepares for Apple's player), and handed back to mpv at the new
/// position when it ends.
@MainActor
final class MPVPictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    /// Shown over mpv's picture while the hand-over runs; Picture in Picture animates out of it.
    let playerLayer = AVPlayerLayer()

    /// Picture in Picture is up: hide the full-screen player.
    var onStarted: (() -> Void)?
    /// The user wants the full player back: show it again, then call the handler.
    var onRestore: ((@escaping (Bool) -> Void) -> Void)?
    /// Picture in Picture ended, with where it got to (`paused` nil: it never took over). `restored` is
    /// false when it was closed.
    var onEnded: ((_ seconds: Double, _ paused: Bool?, _ restored: Bool) -> Void)?
    /// It couldn't start (e.g. a format Apple's player can't play).
    var onFailed: ((String) -> Void)?

    private var player: AVPlayer?
    private var controller: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []
    private var restored = false
    private var startSeconds: Double = 0
    private var didStart = false
    private var isFinishing = false
    /// The AVPlayer started playing and mpv was paused.
    private var tookOver = false

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    var isRunning: Bool { player != nil }

    /// Where the Picture in Picture playback is, while it runs.
    var currentSeconds: Double? {
        guard let time = player?.currentTime().seconds, time.isFinite else { return nil }
        return time
    }

    var isPaused: Bool { (player?.rate ?? 0) == 0 }
    var durationSeconds: Double? {
        guard let duration = player?.currentItem?.duration.seconds, duration.isFinite else { return nil }
        return duration
    }

    func play() { player?.play() }
    func pause() { player?.pause() }
    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600))
    }

    /// Loads `url` in an AVPlayer at `seconds`, and starts Picture in Picture once it can.
    /// `willPlay` is called when the AVPlayer takes over (pause mpv then).
    func start(url: URL, at seconds: Double, willPlay: @escaping () -> Void) {
        guard player == nil else { return }
        restored = false
        didStart = false
        isFinishing = false
        tookOver = false
        startSeconds = seconds
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        self.player = player
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.opacity = 0

        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller

        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.statusChanged(item, willPlay: willPlay) }
        })
        if let controller {
            observations.append(controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.tryStart() }
            })
        }
        // Nothing within 20 s (no network, server busy): give up instead of waiting forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.player === player, !self.didStart else { return }
            self.fail(String(localized: "Picture in Picture couldn't start."))
        }
    }

    /// Ends Picture in Picture without handing back (the player is closing).
    func stop() {
        isFinishing = true
        controller?.stopPictureInPicture()
        cleanUp()
    }

    // MARK: - Private

    private func statusChanged(_ item: AVPlayerItem, willPlay: @escaping () -> Void) {
        switch item.status {
        case .readyToPlay:
            guard let player, !tookOver else { return }
            Task {
                if startSeconds > 1 {
                    await player.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                                      toleranceBefore: .zero, toleranceAfter: .zero)
                }
                willPlay()
                tookOver = true
                player.play()
                playerLayer.opacity = 1
                tryStart()
            }
        case .failed:
            fail(String(localized: "Picture in Picture isn't available for this video."))
        default:
            break
        }
    }

    private func tryStart() {
        // Only once Apple's player is at the right spot and playing.
        guard let controller, player != nil, tookOver, !didStart, controller.isPictureInPicturePossible else { return }
        didStart = true
        controller.startPictureInPicture()
    }

    private func fail(_ message: String) {
        guard player != nil, !isFinishing else { return }
        isFinishing = true
        let seconds = currentSeconds ?? startSeconds
        let paused: Bool? = tookOver ? isPaused : nil
        cleanUp()
        onFailed?(message)
        onEnded?(seconds, paused, true)
    }

    private func cleanUp() {
        observations = []
        player?.pause()
        playerLayer.player = nil
        playerLayer.opacity = 0
        player = nil
        controller = nil
    }

    // MARK: - AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onStarted?() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            didStart = false
            fail(String(localized: "Picture in Picture couldn't start."))
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            restored = true
            if let onRestore { onRestore(completionHandler) } else { completionHandler(true) }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard !isFinishing else { return }
            isFinishing = true
            let seconds = currentSeconds ?? startSeconds
            let paused = isPaused
            let restored = restored
            cleanUp()
            onEnded?(seconds, paused, restored)
        }
    }
}
