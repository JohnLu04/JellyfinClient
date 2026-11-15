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
    private var steering: NativeABRSteering?

    init(url: URL, startSeconds: Double, session: PlaybackSession?) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = PlaybackBuffer.seconds   // Settings → Buffer
        player = AVPlayer(playerItem: item)
        self.session = session
        self.startSeconds = startSeconds
        super.init()
        if let adaptive = session?.adaptive {
            steering = NativeABRSteering(rungs: adaptive.rungs, item: item)
            steering?.start()
        }
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
        steering?.stop()
        steering = nil
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
                #if DEBUG
                debugScript()
                #endif
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

    #if DEBUG
    private func debugScript() {
        guard let script = ProcessInfo.processInfo.environment["JF_DEBUG_SKIPS"] else { return }
        let steps = script.split(separator: ",").compactMap { part -> (Int, Double)? in
            let pair = part.split(separator: ":")
            guard pair.count == 2, let at = Int(pair[0]), let by = Double(pair[1]) else { return nil }
            return (at, by)
        }
        Task { [weak self] in
            for second in 1...60 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let item = self.player.currentItem else { return }
                for step in steps where step.0 == second {
                    print("[NativeDebug] skip \(step.1)")
                    _ = await self.player.seek(to: CMTime(seconds: self.player.currentTime().seconds + step.1, preferredTimescale: 600))
                }
                let ranges = item.seekableTimeRanges.map { "\(Int($0.timeRangeValue.start.seconds))-\(Int($0.timeRangeValue.end.seconds))" }
                print("[NativeDebug] t=\(second) time=\(String(format: "%.1f", self.player.currentTime().seconds)) duration=\(item.duration.seconds) rate=\(self.player.rate) status=\(self.player.timeControlStatus.rawValue) seekable=\(ranges)")
            }
        }
    }
    #endif

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
