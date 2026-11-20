import AVKit
import CoreMedia
import UIKit

/// Picture in Picture for mpv, the way Streamyfin does it.
///
/// mpv draws into an AVSampleBufferDisplayLayer (`vo=avfoundation`), which Picture in Picture can show
/// directly: nothing is handed over or reloaded, mpv simply plays on. With `autoStart` it also starts
/// by itself when the app is left while a video plays. A timebase on the layer tells the system where
/// playback is and whether it runs, for the progress bar and the play/pause button in the window.
@MainActor
final class MPVPictureInPicture: NSObject {
    /// The window is up: hide the full-screen player.
    var onStarted: (() -> Void)?
    /// The user wants the full player back: show it again, then call the handler.
    var onRestore: ((@escaping (Bool) -> Void) -> Void)?
    /// The window closed; `restored` is false when it was closed with ×.
    var onEnded: ((_ restored: Bool) -> Void)?
    /// It couldn't start.
    var onFailed: ((String) -> Void)?
    /// About to start / just ended: the full-screen picture switches between the window's fit and the
    /// user's zoom.
    var onWillStart: (() -> Void)?
    var onDidStop: (() -> Void)?

    /// What the window's buttons do and what it shows.
    var play: (() -> Void)?
    var pause: (() -> Void)?
    var skip: ((Double) -> Void)?

    /// Read by the system from any thread; kept up to date by `update(...)`.
    nonisolated(unsafe) private var cachedPlaying = false
    nonisolated(unsafe) private var cachedDuration: Double = 0

    private weak var layer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var restored = false
    /// The one controller allowed to start by itself (AVKit allows only one).
    private static weak var automaticStartOwner: MPVPictureInPicture?

    static var isSupported: Bool { supported }
    private static let supported = AVPictureInPictureController.isPictureInPictureSupported()

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    var debugPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    /// Sets up Picture in Picture for the layer mpv draws into. Call once the first frame is shown.
    func prepare(layer: AVSampleBufferDisplayLayer, playing: Bool, at seconds: Double) {
        guard controller == nil, Self.isSupported else { return }
        self.layer = layer
        var newTimebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                           timebaseOut: &newTimebase) == noErr, let newTimebase {
            timebase = newTimebase
            CMTimebaseSetTime(newTimebase, time: CMTime(seconds: max(seconds, 0), preferredTimescale: 1000))
            CMTimebaseSetRate(newTimebase, rate: playing ? 1 : 0)
            layer.controlTimebase = newTimebase
        }
        cachedPlaying = playing
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = false
        self.controller = controller
    }

    /// Start by itself when the app is left while playing (swipe home), like Safari or Streamyfin.
    func setAutoStart(_ enabled: Bool) {
        guard let controller else { return }
        if enabled {
            if Self.automaticStartOwner !== self {
                Self.automaticStartOwner?.controller?.canStartPictureInPictureAutomaticallyFromInline = false
                Self.automaticStartOwner = self
            }
        } else if Self.automaticStartOwner === self {
            Self.automaticStartOwner = nil
        }
        controller.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    /// The Picture in Picture button in the player.
    func start() {
        guard let controller else {
            onFailed?(String(localized: "Picture in Picture couldn't start."))
            return
        }
        guard controller.isPictureInPicturePossible else {
            onFailed?(String(localized: "Picture in Picture isn't available for this video."))
            return
        }
        restored = false
        controller.startPictureInPicture()
    }

    /// Where playback is, for the window's progress bar.
    func update(seconds: Double) {
        guard let timebase, seconds >= 0 else { return }
        CMTimebaseSetTime(timebase, time: CMTime(seconds: seconds, preferredTimescale: 1000))
        if isActive { controller?.invalidatePlaybackState() }
    }

    func update(duration: Double) {
        cachedDuration = duration
    }

    func update(playing: Bool) {
        cachedPlaying = playing
        if let timebase { CMTimebaseSetRate(timebase, rate: playing ? 1 : 0) }
        if isActive { controller?.invalidatePlaybackState() }
    }

    /// Closes the window and goes back to the full player.
    func end() {
        restored = true
        controller?.stopPictureInPicture()
    }

    /// Ends Picture in Picture without coming back (the player is closing).
    func stop() {
        onEnded = nil
        setAutoStart(false)
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
        layer?.controlTimebase = nil
        timebase = nil
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension MPVPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            restored = false
            onWillStart?()
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onStarted?() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            onDidStop?()
            onFailed?(String(localized: "Picture in Picture couldn't start."))
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
            onDidStop?()
            onEnded?(restored)
            restored = false
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension MPVPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in playing ? self.play?() : self.pause?() }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        let seconds = cachedDuration
        return seconds > 0
            ? CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 1000))
            : CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        !cachedPlaying
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        let seconds = CMTimeGetSeconds(skipInterval)
        Task { @MainActor in self.skip?(seconds) }
        completionHandler()
    }
}
