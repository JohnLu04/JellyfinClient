import Observation
import QuartzCore
import UIKit

/// CAMetalLayer that ignores MoltenVK's temporary 1×1 drawable size (prevents flicker / stuck 1×1 output)
/// and applies EDR changes on the main thread. See https://github.com/mpv-player/mpv/pull/13651
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

/// State and controls for one mpv playback, plus audio/subtitle switching.
///
/// Track menus list the server's streams (nice names, external subtitles included). Switching:
/// - direct play: the file contains every embedded track → switch instantly in mpv (`aid`/`sid`);
///   external or delivered text subtitles are added with `sub-add`.
/// - transcoding: the stream only contains the chosen audio (and maybe a burned-in subtitle) → ask the
///   server for a new stream with the new tracks and continue at the current position.
/// - local files: menus list mpv's own tracks.
@Observable @MainActor
final class MPVPlayerController: PlaybackEngine {
    struct TrackOption: Identifiable, Hashable {
        let id: Int        // Jellyfin stream index (server playback) or mpv track id (local files)
        let label: String
    }

    let title: String
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var isSwitching = false
    private(set) var errorMessage: String?
    private(set) var audioOptions: [TrackOption] = []
    private(set) var subtitleOptions: [TrackOption] = []
    private(set) var selectedAudio: Int?
    private(set) var selectedSubtitle: Int?

    @ObservationIgnored var onReady: (() -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Track changes made in the player, so progress reports carry the current audio/subtitle.
    @ObservationIgnored var onSelectionChange: ((TrackSelection) -> Void)?
    @ObservationIgnored var reloader: ((TrackSelection) async throws -> PlaybackSession)?

    @ObservationIgnored let layer = MPVMetalLayer()
    @ObservationIgnored private var core: MPVCore?
    @ObservationIgnored private var session: PlaybackSession?
    @ObservationIgnored private var url: URL
    @ObservationIgnored private let startSeconds: Double
    @ObservationIgnored private var addedSubtitles: [Int: Int] = [:]   // Jellyfin index → mpv track id
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var subtitleScale: Double = 1

    init(title: String, url: URL, startSeconds: Double, session: PlaybackSession?) {
        self.title = title
        self.url = url
        self.startSeconds = startSeconds
        self.session = session
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor
        if let session {
            audioOptions = session.audioStreams.map { TrackOption(id: $0.index, label: $0.label) }
            subtitleOptions = session.subtitleStreams.map { TrackOption(id: $0.index, label: $0.label) }
            selectedAudio = session.selection.audioIndex
            selectedSubtitle = session.selection.subtitleIndex
        }
    }

    /// Called by the video view once it has a real size (mpv needs a sized layer to set up rendering).
    func startIfNeeded() {
        guard core == nil, errorMessage == nil else { return }
        guard let core = MPVCore(layer: layer) else {
            errorMessage = String(localized: "mpv could not be started on this device.")
            return
        }
        self.core = core
        core.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observeLifecycle()
        core.setString("sub-scale", String(format: "%.2f", subtitleScale))
        load(url, from: startSeconds)
    }

    /// mpv scales subtitles with the window height, which makes them huge in portrait. Shrink them there.
    func updateSubtitleScale(for size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let scale = min(1, max(0.45, (size.width / size.height) / (16.0 / 9.0)))
        subtitleScale = scale
        core?.setString("sub-scale", String(format: "%.2f", scale))
    }

    // MARK: - Controls

    func togglePause() { core?.setFlag("pause", !isPaused) }

    func seek(to seconds: Double) {
        position = seconds
        core?.command(["seek", String(format: "%.3f", seconds), "absolute"])
    }

    func skip(by seconds: Double) {
        core?.command(["seek", String(format: "%.3f", seconds), "relative"])
    }

    func selectAudio(_ id: Int) {
        guard id != selectedAudio else { return }
        selectedAudio = id
        guard let session else {
            core?.setString("aid", String(id))
            return
        }
        if session.playMethod == .directPlay {
            applyAudio()
            notifySelection()
        } else {
            reloadStream()
        }
    }

    func selectSubtitle(_ id: Int?) {
        guard id != selectedSubtitle else { return }
        selectedSubtitle = id
        guard let session else {
            core?.setString("sid", id.map(String.init) ?? "no")
            return
        }
        // A burned-in subtitle can only be changed by a new stream; same for image subtitles while transcoding.
        let needsNewStream = session.hasBurnedInSubtitle
            || (session.playMethod != .directPlay && session.subtitleStream(id).map { !$0.isTextSubtitle } == true)
        if needsNewStream {
            reloadStream()
        } else {
            applySubtitle()
            notifySelection()
        }
    }

    private func notifySelection() {
        let selection = TrackSelection(audioIndex: selectedAudio, subtitleIndex: selectedSubtitle)
        session?.selection = selection
        onSelectionChange?(selection)
    }

    // MARK: - PlaybackEngine

    var currentSeconds: Double { position }
    var isPausedNow: Bool { isPaused }

    func teardown() {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
        core?.onEvent = nil
        core?.destroy()
        core = nil
    }

    // MARK: - Events

    private func handle(_ event: MPVEvent) {
        switch event {
        case let .property(name, value):
            switch (name, value) {
            case let ("time-pos", .double(seconds)):
                position = seconds
                if isBuffering && !isSwitching { isBuffering = false }
            case let ("duration", .double(seconds)):
                duration = seconds
            case let ("pause", .flag(paused)):
                isPaused = paused
                onStateChange?()
            case let ("paused-for-cache", .flag(buffering)):
                isBuffering = buffering
            case ("track-list/count", _):
                if session == nil { refreshLocalTracks() }
            case let ("aid", .string(value)):
                debugLog("aid=\(value ?? "nil")")
                if session == nil { selectedAudio = value.flatMap(Int.init) }
            case let ("sid", .string(value)):
                debugLog("sid=\(value ?? "nil")")
                if session == nil { selectedSubtitle = value.flatMap(Int.init) }
            default:
                break
            }
        case .fileLoaded:
            isSwitching = false
            applySelection()
            if !didStart {
                didStart = true
                onReady?()
            }
        case let .endFile(eof, error):
            if eof {
                onFinished?()
            } else if let error {
                isSwitching = false
                errorMessage = String(localized: "Playback failed: \(error)")
            }
        }
    }

    // MARK: - Tracks

    private func load(_ url: URL, from seconds: Double) {
        core?.setString("start", seconds > 1 ? String(format: "%.3f", seconds) : "none")
        core?.command(["loadfile", url.absoluteString, "replace"])
    }

    private func applySelection() {
        guard session != nil else {
            refreshLocalTracks()
            return
        }
        applyAudio()
        applySubtitle()
    }

    private func applyAudio() {
        guard let session, session.playMethod == .directPlay, let index = selectedAudio,
              let id = mpvTrackID(forEmbedded: index, in: session.audioStreams, type: "audio") else { return }
        core?.setString("aid", String(id))
    }

    private func applySubtitle() {
        guard let core, let session else { return }
        guard let stream = session.subtitleStream(selectedSubtitle) else {
            core.setString("sid", "no")
            return
        }
        if let id = addedSubtitles[stream.index] {
            core.setString("sid", String(id))
            return
        }
        if session.playMethod == .directPlay, stream.isExternal != true,
           let id = mpvTrackID(forEmbedded: stream.index, in: session.subtitleStreams, type: "sub") {
            core.setString("sid", String(id))
            return
        }
        if session.hasBurnedInSubtitle {
            core.setString("sid", "no")      // already part of the picture
            return
        }
        guard let subtitleURL = session.api.subtitleURL(itemId: session.item.id, mediaSourceId: session.source.id, stream: stream) else { return }
        let index = stream.index
        let urlString = subtitleURL.absoluteString
        core.commandInBackground(["sub-add", urlString, "select", stream.label, stream.language ?? "und"]) { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self, ok, let core = self.core else { return }
                if let track = core.tracks().last(where: { $0.type == "sub" && $0.isExternal }) {
                    self.addedSubtitles[index] = track.id
                }
                // The user may have picked something else while the file was loading.
                if self.selectedSubtitle != index { self.applySubtitle() }
            }
        }
    }

    /// Embedded tracks keep their order in the file, so the n-th embedded server stream is mpv's n-th track.
    private func mpvTrackID(forEmbedded index: Int, in streams: [MediaStream], type: String) -> Int? {
        guard let ordinal = streams.embeddedOrdinal(of: index) else { return nil }
        let ids = (core?.tracks() ?? []).filter { $0.type == type && !$0.isExternal }.map(\.id)
        return ordinal < ids.count ? ids[ordinal] : nil
    }

    private func refreshLocalTracks() {
        guard session == nil, let core else { return }
        let tracks = core.tracks()
        audioOptions = tracks.filter { $0.type == "audio" }.map { TrackOption(id: $0.id, label: $0.label) }
        subtitleOptions = tracks.filter { $0.type == "sub" }.map { TrackOption(id: $0.id, label: $0.label) }
        selectedAudio = tracks.first { $0.type == "audio" && $0.isSelected }?.id
        selectedSubtitle = tracks.first { $0.type == "sub" && $0.isSelected }?.id
    }

    private func reloadStream() {
        guard let reloader else { return }
        isSwitching = true
        let resumeAt = position
        let selection = TrackSelection(audioIndex: selectedAudio, subtitleIndex: selectedSubtitle)
        Task {
            do {
                let newSession = try await reloader(selection)
                session = newSession
                addedSubtitles = [:]
                url = newSession.url
                load(newSession.url, from: resumeAt)
            } catch {
                isSwitching = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[MPVPlayer] \(message())")
        #endif
    }

    // MARK: - Background

    private func observeLifecycle() {
        let center = NotificationCenter.default
        // Rendering into a hidden layer can leave a black picture after returning; pause video output instead.
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.core?.setString("vid", "no") }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.core?.setString("vid", "auto") }
        })
    }
}
