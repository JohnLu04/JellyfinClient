import AVKit
import UIKit

/// Apple's system player (AVPlayerViewController).
@MainActor
final class NativePlayerEngine: NSObject, PlaybackEngine, AVPlayerViewControllerDelegate {
    var onReady: (() -> Void)?
    var onStateChange: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let player: AVPlayer
    private let session: PlaybackSession?
    private let startSeconds: Double
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var didStart = false

    init(url: URL, startSeconds: Double, session: PlaybackSession?) {
        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        self.session = session
        self.startSeconds = startSeconds
        super.init()
    }

    func makeViewController() -> UIViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.modalPresentationStyle = .fullScreen

        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.statusChanged(item) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onStateChange?() }
        }
        return controller
    }

    // MARK: PlaybackEngine

    var currentSeconds: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var isPausedNow: Bool { player.timeControlStatus == .paused }

    func teardown() {
        statusObservation = nil
        rateObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Private

    private func statusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay where !didStart:
            didStart = true
            Task {
                await applySelection(to: item)
                if startSeconds > 1 {
                    await player.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                                      toleranceBefore: .zero, toleranceAfter: .zero)
                }
                player.play()
                onReady?()
            }
        case .failed:
            #if DEBUG
            print("[Native] failed: \(item.error?.localizedDescription ?? "unknown")")
            #endif
        default:
            break
        }
    }

    /// For direct play the file contains all tracks; pick the chosen ones. (HLS streams already contain the
    /// server-selected audio, and AVKit's own menu still lets the user switch what's available.)
    private func applySelection(to item: AVPlayerItem) async {
        guard let session, session.playMethod == .directPlay else { return }
        if let index = session.selection.audioIndex, let ordinal = session.audioStreams.embeddedOrdinal(of: index),
           let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), ordinal < group.options.count {
            item.select(group.options[ordinal], in: group)
        }
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            if let index = session.selection.subtitleIndex,
               let ordinal = session.subtitleStreams.embeddedOrdinal(of: index), ordinal < group.options.count {
                item.select(group.options[ordinal], in: group)
            } else if group.allowsEmptySelection {
                item.select(nil, in: group)
            }
        }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        MainActor.assumeIsolated {
            _ = coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard !context.isCancelled else { return }
                MainActor.assumeIsolated { self?.onDismiss?() }
            }
        }
    }
}
