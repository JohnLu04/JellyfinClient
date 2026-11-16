import ActivityKit
import UIKit

/// Shows the download queue's progress as a Live Activity on the Lock Screen and in the Dynamic
/// Island (drawn by the DownloadActivity widget extension).
///
/// iOS only lets an app *start* a Live Activity while it is in the foreground, so it starts when the
/// user starts a download (or opens the app with downloads pending). Updating works in the background
/// as long as the app runs, which the download keep-alive takes care of; the activity then follows the
/// queue from title to title and ends a few minutes after the last one finished.
@MainActor
enum DownloadActivityController {
    private typealias State = DownloadActivityAttributes.ContentState

    private static var activity: Activity<DownloadActivityAttributes>?
    private static var loop: Task<Void, Never>?
    private static var lastState: State?
    private static var lastUpdate = Date.distantPast
    /// The title shown last, to show how it ended once the queue is empty.
    private static var lastItemId: String?
    private static var posters: [String: Data] = [:]

    /// Starts the activity if downloads are pending (foreground only), or picks up the one still
    /// shown from before the app was closed.
    static func start() {
        guard DownloadManager.shared.hasActiveDownloads else { return }
        adoptExisting()
        guard activity == nil else { startLoop(); refresh(force: true); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            DownloadDiagnostics.log("Lock Screen progress is turned off for this app in Settings")
            return
        }
        guard let state = currentState() else { return }
        // A finished or paused activity still showing: the new one replaces it.
        for old in Activity<DownloadActivityAttributes>.activities where old.activityState == .ended {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            activity = try Activity.request(attributes: DownloadActivityAttributes(),
                                            content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            lastState = state
            lastUpdate = .now
            lastItemId = state.itemId
            DownloadDiagnostics.log("Lock Screen progress shown")
            startLoop()
        } catch {
            DownloadDiagnostics.log("Lock Screen progress unavailable: \(DownloadDiagnostics.describe(error as NSError))")
        }
    }

    /// After launch: keep following an activity from before, or remove it if nothing is pending.
    static func appLaunched() {
        #if DEBUG
        // JF_DEBUG_DOWNLOAD="e1:0:8:15" downloads e1 (0 = original, else Mbit/s), pauses at 8 s, resumes at 15 s.
        if let script = ProcessInfo.processInfo.environment["JF_DEBUG_DOWNLOAD"], let stored = SessionStorage.load() {
            let parts = script.split(separator: ":").map(String.init)
            let api = JellyfinAPI(session: stored)
            Task {
                guard parts.count == 4, let mbit = Double(parts[1]), let pauseAt = Double(parts[2]), let resumeAt = Double(parts[3]),
                      let item = try? await api.item(id: parts[0]) else { return }
                DownloadManager.shared.start(item: item, api: api, mbit: mbit > 0 ? mbit : nil)
                try? await Task.sleep(for: .seconds(pauseAt))
                print("[DLDebug] pause at \(DownloadManager.shared.record(for: item.id)?.bytesWritten ?? 0) bytes")
                DownloadManager.shared.pause(id: item.id)
                try? await Task.sleep(for: .seconds(resumeAt - pauseAt))
                print("[DLDebug] resume, state=\(DownloadManager.shared.record(for: item.id)?.state.rawValue ?? "-")")
                DownloadManager.shared.resume(id: item.id)
            }
        }
        if let id = ProcessInfo.processInfo.environment["JF_DEBUG_PLAY_ITEM"], let stored = SessionStorage.load() {
            let api = JellyfinAPI(session: stored)
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let item = try? await api.item(id: id) {
                    try? await PlaybackCoordinator.shared.playWithDefaults(item, api: api, fromStart: true)
                }
            }
        }
        if let id = ProcessInfo.processInfo.environment["JF_DEBUG_PLAY_DOWNLOAD"],
           let record = DownloadManager.shared.record(for: id) {
            Task {
                try? await Task.sleep(for: .seconds(3))
                DownloadManager.shared.play(record)
            }
        }
        #endif
        if DownloadManager.shared.hasActiveDownloads {
            adoptExisting()
            if activity != nil { startLoop(); refresh(force: true) }
        } else {
            for stale in Activity<DownloadActivityAttributes>.activities {
                Task { await stale.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    /// Brings the activity up to date: at most once a second, right away when the title or its state
    /// changes, and ends it once the queue is empty.
    static func refresh(force: Bool = false) {
        guard let activity else { return }
        guard let state = currentState() else {
            finish(activity)
            return
        }
        guard state != lastState else { return }
        let changed = state.itemId != lastState?.itemId || state.phase != lastState?.phase || state.status != lastState?.status
        guard force || changed || Date.now.timeIntervalSince(lastUpdate) >= 1 else { return }
        lastState = state
        lastUpdate = .now
        lastItemId = state.itemId
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    // MARK: - Private

    private static func adoptExisting() {
        guard activity == nil else { return }
        let existing = Activity<DownloadActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        activity = existing.first
        for extra in existing.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
        if let activity { lastItemId = activity.content.state.itemId }
    }

    private static func startLoop() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refresh()
            }
        }
    }

    /// The queue is empty: show how the last title ended for a few minutes, then remove the activity.
    private static func finish(_ activity: Activity<DownloadActivityAttributes>) {
        loop?.cancel()
        loop = nil
        self.activity = nil
        let manager = DownloadManager.shared
        var state = lastState ?? activity.content.state
        guard let id = lastItemId, let record = manager.record(for: id) else {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }   // deleted: nothing to report
            reset()
            return
        }
        state.itemId = record.id
        state.title = record.name
        state.queued = 0
        state.bytesPerSecond = nil
        state.bytesWritten = record.bytesWritten
        if record.state == .paused {
            state.phase = .waiting
            state.status = String(localized: "Paused")
        } else if record.state == .completed {
            state.phase = .completed
            state.status = String(localized: "Download Complete")
            state.progress = 1
            state.totalBytes = record.bytesWritten
        } else {
            state.phase = .failed
            state.status = String(localized: "Download Failed")
        }
        let final = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(final, dismissalPolicy: .after(.now.addingTimeInterval(5 * 60))) }
        DownloadDiagnostics.log("Lock Screen progress ended (\(state.phase.rawValue))")
        reset()
    }

    private static func reset() {
        lastState = nil
        lastItemId = nil
        posters = [:]
    }

    /// The title being downloaded (or next in line) and how far it is.
    private static func currentState() -> State? {
        let manager = DownloadManager.shared
        let active = manager.records.filter(\.isActive)
        // The queue starts the oldest first (records are kept newest first).
        guard let record = active.first(where: { $0.state == .downloading })
                ?? active.last(where: { $0.state == .queued && $0.isPartlyThere })
                ?? active.last else { return nil }

        let phase: State.Phase
        let status: String
        if record.state == .downloading, record.errorMessage == nil {
            phase = .downloading
            status = record.fileName == nil
                ? String(localized: "Downloading now")
                : String(localized: "Loading audio tracks & subtitles")
        } else {
            phase = .waiting
            status = record.errorMessage != nil ? String(localized: "Retrying shortly") : String(localized: "Queued")
        }
        let subtitle = [record.subtitle, record.qualityLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return State(itemId: record.id, title: record.name, subtitle: subtitle.isEmpty ? nil : subtitle,
                     status: status, phase: phase, progress: record.progress, bytesWritten: record.bytesWritten,
                     totalBytes: record.expectedBytes, bytesPerSecond: record.fileName == nil ? manager.speeds[record.id].map { ($0 / 1024).rounded() * 1024 } : nil,
                     queued: active.count - 1, poster: poster(for: record))
    }

    /// A tiny JPEG of the saved poster; the activity's data may not exceed 4 KB in all.
    private static func poster(for record: DownloadRecord) -> Data? {
        if let cached = posters[record.id] { return cached }
        guard let url = DownloadManager.shared.posterURL(for: record),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        for width in [96.0, 80, 66, 54] {
            let size = CGSize(width: width, height: width * 1.5)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let scale = max(size.width / image.size.width, size.height / image.size.height)
                let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height))
            }
            for quality in [0.6, 0.45, 0.3] {
                if let data = scaled.jpegData(compressionQuality: quality), data.count <= 2_000 {
                    posters[record.id] = data
                    return data
                }
            }
        }
        return nil
    }
}

private extension DownloadRecord {
    var isPartlyThere: Bool { (retryCount ?? 0) > 0 || fileName != nil || (hls?.nextSegment ?? 0) > 0 || hls?.hasInitSegment == true }
}
