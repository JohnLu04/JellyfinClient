import AVFoundation
import UIKit

/// Keeps the app running in the background while the in-app download engine works, by playing
/// silence through an audio session that mixes with other apps (Music etc. keep playing, nothing
/// shows on the lock screen). The app already declares the audio background mode for playback.
///
/// Only used for the in-app engine — iOS' own download service needs no help — and only while
/// downloads are active and no video is open (the player owns the audio session then).
@MainActor
final class BackgroundAudioKeepAlive {
    static let shared = BackgroundAudioKeepAlive()

    private var player: AVAudioPlayer?
    private(set) var isRunning = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .ended else { return }
            Task { @MainActor in self?.resumeAfterInterruption() }
        }
    }

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            self.player = player
            isRunning = true
            DownloadDiagnostics.log("Background keep-alive started")
        } catch {
            DownloadDiagnostics.log("Background keep-alive failed: \(DownloadDiagnostics.describe(error as NSError))")
        }
    }

    func stop() {
        guard isRunning else { return }
        player?.stop()
        player = nil
        isRunning = false
        // Back to the player's normal setup (as at app start).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        if !PlaybackCoordinator.shared.isPlayerOpen {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        DownloadDiagnostics.log("Background keep-alive stopped")
    }

    private func resumeAfterInterruption() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
    }

    /// One second of 8 kHz mono 16-bit silence as a WAV file.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8000
        let samples = Int(sampleRate)
        let dataSize = UInt32(samples * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()
}
