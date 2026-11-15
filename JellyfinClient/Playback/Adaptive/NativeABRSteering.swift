import AVFoundation

/// Automatic quality for Apple's player. AVPlayer switches between the ladder's variants by itself and
/// seamlessly, but tends to hold a rung while the buffer drains. This applies the same rules as for mpv
/// on top: every second it reads the buffered seconds and AVPlayer's measured download rate and sets
/// `preferredPeakBitRate`, which makes AVPlayer step down (or allows it to step up again).
@MainActor
final class NativeABRSteering {
    private let rungs: [AdaptiveStream.Rung]
    private weak var item: AVPlayerItem?
    private var task: Task<Void, Never>?

    private var cap: Int
    private var fast: Double?
    private var slow: Double?
    private var healthy = false
    private var upVotes = 0
    private var lowReadings = 0
    private var lastChange = Date.distantPast
    /// Last access-log reading, to turn its running totals into a rate per second.
    private var lastLog: (start: Date?, bytes: Int64, seconds: Double)?

    init(rungs: [AdaptiveStream.Rung], item: AVPlayerItem) {
        self.rungs = rungs
        self.item = item
        self.cap = rungs.count - 1
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private var thresholds: (up: Double, low: Double, panic: Double) {
        let target = PlaybackBuffer.seconds
        return (min(20, target * 0.6), min(12, target * 0.35), min(5, target * 0.15))
    }

    private func tick() {
        guard let item else { return }
        let now = item.currentTime().seconds
        // While AVPlayer switches variants its loaded ranges briefly disappear: no reading, no decision.
        guard let range = item.loadedTimeRanges.map(\.timeRangeValue)
            .first(where: { $0.start.seconds <= now + 0.5 && now <= $0.end.seconds }) else { return }
        let buffer = range.end.seconds - now
        if buffer >= thresholds.low + 3 { healthy = true }

        // Rate of what was transferred since the last tick (the log's own average reacts too slowly).
        if let event = item.accessLog()?.events.last {
            let bytes = event.numberOfBytesTransferred
            let seconds = event.transferDuration
            if let last = lastLog, last.start == event.playbackStartDate, seconds - last.seconds > 0.3, bytes > last.bytes {
                let sample = Double(bytes - last.bytes) * 8 / (seconds - last.seconds)
                if let current = fast, sample < current * 0.5 { fast = sample } else { fast = fast.map { $0 * 0.6 + sample * 0.4 } ?? sample }
                slow = slow.map { $0 * 0.9 + sample * 0.1 } ?? sample
            }
            lastLog = (event.playbackStartDate, bytes, seconds)
        }
        let estimate = [fast, slow].compactMap { $0 }.min()

        var target = cap
        if let estimate {
            let affordable = rungs.lastIndex { Double($0.totalBps) * 1.1 <= estimate * 0.75 } ?? 0
            if affordable < cap {
                target = affordable
                upVotes = 0
            } else if affordable > cap, healthy, buffer >= thresholds.up {
                upVotes += 1
                if upVotes >= 6 { target = cap + 1; upVotes = 0 }   // about one segment of confirmation
            } else {
                upVotes = 0
            }
        }
        // Buffer rules need two low readings in a row, and leave AVPlayer a few seconds after a change.
        lowReadings = buffer < thresholds.low ? lowReadings + 1 : 0
        if healthy, lowReadings >= 2, Date.now.timeIntervalSince(lastChange) > 6 {
            target = buffer < thresholds.panic ? 0 : min(target, max(cap - 1, 0))
        }
        guard target != cap else { return }
        abrLog.notice("Apple player cap \(self.rungs[self.cap].mbit) → \(self.rungs[target].mbit) Mbit/s (estimate \(String(format: "%.1f", (estimate ?? 0) / 1_000_000)) Mbit/s, buffer \(Int(buffer)) s)")
        cap = target
        lastChange = .now
        // The top rung means "no cap"; otherwise allow exactly up to this rung's advertised bandwidth.
        item.preferredPeakBitRate = cap == rungs.count - 1 ? 0 : Double(rungs[cap].totalBps) * 1.1 + 1_000
    }
}
