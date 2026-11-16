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
    /// Streaming quality of this playback in Mbit/s (0 = original, -1 = automatic); nil for local files.
    private(set) var currentQuality: Double?
    /// Picture in Picture: idle, preparing (Apple's player loads) or active.
    enum PiPState { case idle, preparing, active }
    private(set) var pipState: PiPState = .idle
    /// Why Picture in Picture didn't start, shown briefly.
    var pipMessage: String?

    @ObservationIgnored var onReady: (() -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Track changes made in the player, so progress reports carry the current audio/subtitle.
    @ObservationIgnored var onSelectionChange: ((TrackSelection) -> Void)?
    /// Asks the server for a new stream with these tracks and this quality (Mbit/s, 0 = original, -1 = automatic).
    @ObservationIgnored var reloader: ((TrackSelection, Double) async throws -> PlaybackSession)?
    /// Picture in Picture is up (hide the player screen) / should come back (show it, then call the handler) /
    /// was closed (stop playback).
    @ObservationIgnored var onPiPStarted: (() -> Void)?
    @ObservationIgnored var onPiPRestore: ((@escaping (Bool) -> Void) -> Void)?
    @ObservationIgnored var onPiPClosed: (() -> Void)?
    @ObservationIgnored let pictureInPicture = MPVPictureInPicture()
    /// The stream prepared for Apple's player during Picture in Picture; stopped afterwards.
    @ObservationIgnored private var pipSession: PlaybackSession?

    @ObservationIgnored let layer = MPVMetalLayer()
    @ObservationIgnored private var core: MPVCore?
    /// For the "Video Details" panel (MPVStats.swift).
    var statsCore: MPVCore? { core }
    @ObservationIgnored private(set) var session: PlaybackSession?
    @ObservationIgnored private var url: URL
    @ObservationIgnored private let startSeconds: Double
    @ObservationIgnored private var addedSubtitles: [Int: Int] = [:]   // Jellyfin index → mpv track id
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private let offlineTracks: [PlaybackCoordinator.OfflineTrack]
    @ObservationIgnored private let embeddedAudioTitle: String?
    @ObservationIgnored private var didAddOfflineTracks = false
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    /// Automatic quality: tells the adaptive stream how much is buffered, every second.
    @ObservationIgnored private var bufferReporter: Task<Void, Never>?

    init(title: String, url: URL, startSeconds: Double, session: PlaybackSession?,
         offlineTracks: [PlaybackCoordinator.OfflineTrack] = [], embeddedAudioTitle: String? = nil) {
        self.offlineTracks = offlineTracks
        self.embeddedAudioTitle = embeddedAudioTitle
        self.title = title
        self.url = url
        self.startSeconds = startSeconds
        self.session = session
        let video = session?.source.mediaStreams?.first { $0.type == "Video" }
        if let width = video?.width, let height = video?.height, width > 0, height > 0 {
            videoAspect = Double(width) / Double(height)
        } else {
            videoAspect = 16.0 / 9.0
        }
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor
        if let session {
            audioOptions = session.audioStreams.map { TrackOption(id: $0.index, label: $0.label) }
            subtitleOptions = session.subtitleStreams.map { TrackOption(id: $0.index, label: $0.label) }
            selectedAudio = session.selection.audioIndex
            selectedSubtitle = session.selection.subtitleIndex
            currentQuality = session.maxMbit
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
        load(url, from: startSeconds)
        #if DEBUG
        debugScript()
        #endif
        bufferReporter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let adaptive = self.session?.adaptive else { continue }
                let seconds = self.core?.getString("demuxer-cache-duration").flatMap(Double.init) ?? 0
                adaptive.updateBuffer(seconds)
            }
        }
    }

    /// Display aspect ratio of the video. mpv renders into a surface of exactly this shape, so the
    /// picture fills it without bars and rotating only rescales the finished surface (see MPVLayerHostView).
    @ObservationIgnored private(set) var videoAspect: Double
    /// Called when mpv reports a different aspect than expected; the view then re-lays out the surface.
    @ObservationIgnored var onVideoAspectChange: (() -> Void)?

    // MARK: - Controls

    func togglePause() {
        if pictureInPicture.isRunning {
            pictureInPicture.isPaused ? pictureInPicture.play() : pictureInPicture.pause()
            return
        }
        core?.setFlag("pause", !isPaused)
    }

    func play() {
        if pictureInPicture.isRunning { pictureInPicture.play() } else { core?.setFlag("pause", false) }
    }

    func pause() {
        if pictureInPicture.isRunning { pictureInPicture.pause() } else { core?.setFlag("pause", true) }
    }

    func seek(to seconds: Double) {
        if pictureInPicture.isRunning { pictureInPicture.seek(to: seconds); return }
        position = seconds
        core?.command(["seek", String(format: "%.3f", seconds), "absolute"])
    }

    func skip(by seconds: Double) {
        if pictureInPicture.isRunning {
            pictureInPicture.seek(to: (pictureInPicture.currentSeconds ?? position) + seconds)
            return
        }
        core?.command(["seek", String(format: "%.3f", seconds), "relative"])
    }

    // MARK: - Quality

    /// The source's own bitrate in Mbit/s, if the server told us.
    var sourceMbit: Double? {
        guard let bps = session?.source.bitrate, bps > 0 else { return nil }
        return Double(bps) / 1_000_000
    }

    /// Choices for the quality menu: Original, Automatic and fixed limits below the source's bitrate.
    var qualityChoices: [Double] {
        guard session != nil else { return [] }
        let presets: [Double] = [1, 1.5, 2, 3, 4, 6, 8, 10, 15, 20, 30, 40, 60]
        var limits = presets.filter { limit in sourceMbit.map { limit < $0 * 0.95 } ?? true }
        if let current = currentQuality, current > 0, !limits.contains(current) {
            limits.append(current)
            limits.sort()
        }
        return [0, Bitrate.automatic] + limits.reversed()
    }

    /// Switches the streaming quality while playing: a new stream from the server, continuing where it was.
    func selectQuality(_ mbit: Double) {
        guard session != nil, mbit != currentQuality || errorMessage != nil, !isSwitching, pipState == .idle else { return }
        reloadStream(maxMbit: mbit)
    }

    // MARK: - Picture in Picture

    /// Hands playback to Apple's player and starts Picture in Picture (see MPVPictureInPicture).
    func startPictureInPicture() {
        guard pipState == .idle, MPVPictureInPicture.isSupported, errorMessage == nil else { return }
        pipState = .preparing
        let pip = pictureInPicture
        pip.onStarted = { [weak self] in
            guard let self else { return }
            self.pipState = .active
            self.onPiPStarted?()
        }
        pip.onRestore = { [weak self] completion in
            guard let self, let onPiPRestore = self.onPiPRestore else { return completion(true) }
            onPiPRestore(completion)
        }
        pip.onFailed = { [weak self] message in self?.pipMessage = message }
        pip.onEnded = { [weak self] seconds, paused, restored in self?.pictureInPictureEnded(at: seconds, paused: paused, restored: restored) }
        let wasPaused = isPaused
        Task {
            var url = self.url
            if let session {
                // A stream for Apple's player (mpv's may be a format it can't play).
                do {
                    let native = try await PlaybackResolver.resolve(item: session.item, api: session.api, maxMbit: session.maxMbit,
                                                                    selection: session.selection, player: .native)
                    pipSession = native
                    url = native.url
                } catch {
                    pipState = .idle
                    pipMessage = String(localized: "Picture in Picture couldn't start.")
                    return
                }
            }
            pip.start(url: url, at: position) { [weak self] in
                guard let self else { return }
                self.core?.setFlag("pause", true)
                if wasPaused { pip.pause() }
            }
        }
    }

    private func pictureInPictureEnded(at seconds: Double, paused: Bool?, restored: Bool) {
        pipState = .idle
        if let native = pipSession {
            pipSession = nil
            native.adaptive?.stop()
            if native.playMethod != .directPlay, let id = native.playSessionId {
                Task { try? await native.api.stopTranscoding(playSessionId: id) }
            }
        }
        guard let paused else { return }     // Apple's player never took over: mpv just goes on
        position = seconds
        core?.command(["seek", String(format: "%.3f", seconds), "absolute"])
        guard restored else {
            core?.setFlag("pause", true)
            onPiPClosed?()
            return
        }
        core?.setFlag("pause", paused)
        onStateChange?()
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

    var currentSeconds: Double { pictureInPicture.currentSeconds ?? position }
    var isPausedNow: Bool { pictureInPicture.isRunning ? pictureInPicture.isPaused : isPaused }
    var durationSeconds: Double { duration > 0 ? duration : (pictureInPicture.durationSeconds ?? 0) }

    func teardown() {
        pictureInPicture.onEnded = nil
        pictureInPicture.stop()
        if let native = pipSession {
            pipSession = nil
            native.adaptive?.stop()
            if native.playMethod != .directPlay, let id = native.playSessionId {
                Task { try? await native.api.stopTranscoding(playSessionId: id) }
            }
        }
        bufferReporter?.cancel()
        bufferReporter = nil
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
                // mpv reports every frame; ~5 updates per second are plenty for the UI and keep it responsive.
                if abs(seconds - position) >= 0.2 { position = seconds }
                if isBuffering && !isSwitching { isBuffering = false }
            case let ("video-params/aspect", .double(aspect)):
                adoptVideoAspect(aspect)
            case let ("duration", .double(seconds)):
                duration = seconds
            case let ("pause", .flag(paused)):
                isPaused = paused
                onStateChange?()
            case let ("paused-for-cache", .flag(buffering)):
                isBuffering = buffering
                if buffering, let adaptive = session?.adaptive {
                    abrLog.error("Playback waiting for data at \(adaptive.status.rungMbit) Mbit/s")
                }
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
            addOfflineTracksIfNeeded()
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

    /// Only needed when the guessed aspect was wrong (local files, anamorphic video): resize the surface
    /// once and let mpv set up its output again. Happens right at the start, never on rotation.
    private func adoptVideoAspect(_ aspect: Double) {
        guard aspect.isFinite, aspect > 0.1, abs(aspect - videoAspect) / videoAspect > 0.02 else { return }
        debugLog("video aspect \(videoAspect) -> \(aspect)")
        videoAspect = aspect
        onVideoAspectChange?()
        guard let core, let track = core.getString("vid"), track != "no" else { return }
        core.setString("vid", "no")
        core.setString("vid", track)
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

    /// Downloads: extra audio tracks and subtitle files sit next to the video; mpv adds them as tracks
    /// without switching to them.
    private func addOfflineTracksIfNeeded() {
        guard session == nil, !didAddOfflineTracks, let core else { return }
        didAddOfflineTracks = true
        for track in offlineTracks {
            let command = track.kind == .audio ? "audio-add" : "sub-add"
            core.command([command, track.url.path, "auto", track.title, track.language ?? "und"])
        }
        if !offlineTracks.isEmpty { debugLog("added \(offlineTracks.count) offline track(s)") }
    }

    private func refreshLocalTracks() {
        guard session == nil, let core else { return }
        let tracks = core.tracks()
        let embeddedAudio = tracks.filter { $0.type == "audio" && !$0.isExternal }
        audioOptions = tracks.filter { $0.type == "audio" }.map { track in
            // A transcoded download's own track has no name in the file; use the one from the server.
            if let embeddedAudioTitle, embeddedAudio.count == 1, track.id == embeddedAudio[0].id {
                return TrackOption(id: track.id, label: embeddedAudioTitle)
            }
            return TrackOption(id: track.id, label: track.label)
        }
        subtitleOptions = tracks.filter { $0.type == "sub" }.map { TrackOption(id: $0.id, label: $0.label) }
        selectedAudio = tracks.first { $0.type == "audio" && $0.isSelected }?.id
        selectedSubtitle = tracks.first { $0.type == "sub" && $0.isSelected }?.id
    }

    private func reloadStream(maxMbit: Double? = nil) {
        guard let reloader, let current = session else { return }
        isSwitching = true
        errorMessage = nil      // another quality is also the way out of a failed stream
        let resumeAt = position
        let selection = TrackSelection(audioIndex: selectedAudio, subtitleIndex: selectedSubtitle)
        Task {
            do {
                let newSession = try await reloader(selection, maxMbit ?? current.maxMbit)
                currentQuality = newSession.maxMbit
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

    #if DEBUG
    /// JF_DEBUG_SKIPS="8:+600,14:-10" skips by the given seconds at the given times after start and
    /// prints the position every second, to test seeking without tapping.
    private func debugScript() {
        guard let script = ProcessInfo.processInfo.environment["JF_DEBUG_SKIPS"] else { return }
        // "12:q8" switches to 8 Mbit/s at 12 s, "q-1" automatic, "q0" original; plain numbers skip.
        let qualitySteps = script.split(separator: ",").compactMap { part -> (Int, Double)? in
            let pair = part.split(separator: ":")
            guard pair.count == 2, pair[1].hasPrefix("q"), let at = Int(pair[0]), let mbit = Double(pair[1].dropFirst()) else { return nil }
            return (at, mbit)
        }
        let steps = script.split(separator: ",").compactMap { part -> (Double, Double)? in
            let pair = part.split(separator: ":")
            guard pair.count == 2, let at = Double(pair[0]), let by = Double(pair[1]) else { return nil }
            return (at, by)
        }
        Task { [weak self] in
            for second in 1...90 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if ProcessInfo.processInfo.environment["JF_DEBUG_PAUSE"] != nil, second == 8 || second == 12 {
                    print("[MPVDebug] toggle pause")
                    self.togglePause()
                }
                for step in qualitySteps where step.0 == second {
                    print("[MPVDebug] quality \(step.1)")
                    self.selectQuality(step.1)
                }
                for step in steps where Int(step.0) == second {
                    print("[MPVDebug] skip \(step.1)")
                    self.skip(by: step.1)
                }
                print("[MPVDebug] t=\(second) position=\(String(format: "%.1f", self.position)) duration=\(String(format: "%.1f", self.duration)) quality=\(self.currentQuality ?? -99) switching=\(self.isSwitching) screenOn=\(UIApplication.shared.isIdleTimerDisabled) mpv=\(self.core?.getString("time-pos") ?? "nil")")
            }
        }
    }
    #endif

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
