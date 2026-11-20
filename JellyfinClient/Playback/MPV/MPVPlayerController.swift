import AVFoundation
import Observation
import UIKit

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
    /// Picture in Picture: idle, preparing (starting) or active.
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
    /// The player screen is up: Picture in Picture may start by itself when the app is left.
    @ObservationIgnored private var isScreenVisible = false

    /// What mpv draws into (`vo=avfoundation`); Picture in Picture shows the same layer.
    @ObservationIgnored let layer = AVSampleBufferDisplayLayer()
    /// Zoomed to fill the screen (pinch) instead of showing the whole picture.
    @ObservationIgnored private(set) var fillsScreen = false
    @ObservationIgnored private var viewSize = CGSize.zero
    @ObservationIgnored private var videoSize = CGSize.zero
    @ObservationIgnored private var layerStatusObservation: NSKeyValueObservation?
    /// Decoder resets after the layer failed (bounded, see recoverDecoder).
    @ObservationIgnored private var decoderResets = 0
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
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        if #available(iOS 17.0, *) { layer.wantsExtendedDynamicRangeContent = true }
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
        observeLayerStatus()
        setUpPictureInPicture()
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

    // MARK: - Picture size

    /// The video view's size changed (layout, rotation): keeps the subtitles inside the visible part.
    func viewSizeChanged(_ size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        applySubtitlePosition()
    }

    /// Pinch: fill the screen (edges cut off, never stretched) or show the whole picture.
    func setFillsScreen(_ fill: Bool) {
        guard fill != fillsScreen else { return }
        fillsScreen = fill
        guard !pictureInPicture.isActive else { return }    // the window always shows the whole picture
        applyGravity(fill)
    }

    private func applyGravity(_ fill: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        layer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()
        applySubtitlePosition(fill: fill)
    }

    /// Subtitles are drawn onto the video frames, so zooming would cut off their bottom: move them up into
    /// the part that stays on screen.
    private func applySubtitlePosition(fill: Bool? = nil) {
        let fill = fill ?? (fillsScreen && !pictureInPicture.isActive)
        var position = 100
        if fill, videoSize.width > 0, videoSize.height > 0, viewSize.width > 0, viewSize.height > 0 {
            let scale = max(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
            let shown = min(1, viewSize.height / (videoSize.height * scale))     // share of the height on screen
            if shown < 0.99 { position = Int((100 * (1 - (1 - shown) / 2)).rounded(.down)) - 1 }
        }
        core?.setString("sub-pos", String(position))
    }

    // MARK: - Controls

    func togglePause() {
        core?.setFlag("pause", !isPaused)
    }

    func play() {
        core?.setFlag("pause", false)
    }

    func pause() {
        core?.setFlag("pause", true)
    }

    func seek(to seconds: Double) {
        position = seconds
        pictureInPicture.update(seconds: seconds)
        core?.command(["seek", String(format: "%.3f", seconds), "absolute"])
    }

    func skip(by seconds: Double) {
        pictureInPicture.update(seconds: max(0, position + seconds))
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

    /// The Picture in Picture button: the window takes over the picture mpv draws (nothing reloads).
    func startPictureInPicture() {
        guard pipState == .idle, MPVPictureInPicture.isSupported, errorMessage == nil else { return }
        pictureInPicture.start()
    }

    /// Back from the window to the full player (the button while Picture in Picture runs).
    func stopPictureInPicture() {
        pictureInPicture.end()
    }

    /// The player screen appeared or went away (dismissed while Picture in Picture runs, or closed).
    func setScreenVisible(_ visible: Bool) {
        isScreenVisible = visible
        pictureInPicture.setAutoStart(visible && didShowFirstFrame)
    }

    @ObservationIgnored private var didShowFirstFrame = false

    private func setUpPictureInPicture() {
        let pip = pictureInPicture
        pip.play = { [weak self] in self?.play() }
        pip.pause = { [weak self] in self?.pause() }
        pip.skip = { [weak self] seconds in self?.skip(by: seconds) }
        pip.onWillStart = { [weak self] in
            guard let self else { return }
            self.pipState = .preparing
            pip.update(seconds: self.position)
            if self.fillsScreen { self.applyGravity(false) }       // the window shows the whole picture
        }
        pip.onStarted = { [weak self] in
            guard let self else { return }
            self.debugLog("pip started")
            self.pipState = .active
            pip.update(seconds: self.position)
            self.onPiPStarted?()
        }
        pip.onRestore = { [weak self] completion in
            guard let self, let onPiPRestore = self.onPiPRestore else { return completion(true) }
            onPiPRestore(completion)
        }
        pip.onFailed = { [weak self] message in
            self?.debugLog("pip failed: \(message)")
            self?.pipState = .idle
            self?.pipMessage = message
        }
        pip.onDidStop = { [weak self] in
            guard let self else { return }
            if self.fillsScreen { self.applyGravity(true) }
        }
        pip.onEnded = { [weak self] restored in
            guard let self else { return }
            self.debugLog("pip ended, restored=\(restored)")
            self.pipState = .idle
            guard restored else {
                // Closed with ×: stop like the player's close button.
                self.core?.setFlag("pause", true)
                self.onPiPClosed?()
                return
            }
            self.onStateChange?()
        }
    }

    /// The first frame is on screen: Picture in Picture can take the layer over from now on.
    private func firstFrameShown() {
        guard !didShowFirstFrame else { return }
        didShowFirstFrame = true
        pictureInPicture.prepare(layer: layer, playing: !isPaused, at: position)
        pictureInPicture.update(duration: duration)
        pictureInPicture.setAutoStart(isScreenVisible)
        debugLog("pip prepared: supported=\(MPVPictureInPicture.isSupported) screenVisible=\(isScreenVisible)")
        #if DEBUG
        // JF_DEBUG_PIP=8 starts Picture in Picture 8 s after the first frame.
        if let delay = ProcessInfo.processInfo.environment["JF_DEBUG_PIP"].flatMap(Double.init) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.debugLog("pip debug start, possible=\(self?.pictureInPicture.debugPossible ?? false)")
                self?.startPictureInPicture()
            }
        }
        #endif
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
    var durationSeconds: Double { duration }

    func teardown() {
        pictureInPicture.stop()
        layerStatusObservation = nil
        bufferReporter?.cancel()
        bufferReporter = nil
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
                if abs(seconds - position) >= 0.2 {
                    position = seconds
                    if pictureInPicture.isActive { pictureInPicture.update(seconds: seconds) }
                }
                if isBuffering && !isSwitching { isBuffering = false }
            case let ("video-params/w", .int(width)):
                videoSize.width = CGFloat(width)
                applySubtitlePosition()
            case let ("video-params/h", .int(height)):
                videoSize.height = CGFloat(height)
                applySubtitlePosition()
            case let ("duration", .double(seconds)):
                duration = seconds
                pictureInPicture.update(duration: seconds)
            case let ("pause", .flag(paused)):
                isPaused = paused
                pictureInPicture.update(playing: !paused)
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
        case .playbackRestart:
            firstFrameShown()
            if pictureInPicture.isActive { pictureInPicture.update(seconds: position) }
        case .fileLoaded:
            isSwitching = false
            decoderResets = 0
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
        // "12:q8" switches to 8 Mbit/s at 12 s, "q-1" automatic, "q0" original; "20:x" closes the player;
        // plain numbers skip.
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
            for second in 1...150 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if ProcessInfo.processInfo.environment["JF_DEBUG_PAUSE"] != nil, second == 8 || second == 12 {
                    print("[MPVDebug] toggle pause")
                    self.togglePause()
                }
                if script.contains("\(second):x") {
                    print("[MPVDebug] close at \(String(format: "%.1f", self.position))")
                    self.onFinished?()
                    return
                }
                for step in qualitySteps where step.0 == second {
                    print("[MPVDebug] quality \(step.1)")
                    self.selectQuality(step.1)
                }
                for step in steps where Int(step.0) == second {
                    print("[MPVDebug] skip \(step.1)")
                    self.skip(by: step.1)
                }
                print("[MPVDebug] t=\(second) position=\(String(format: "%.1f", self.position)) duration=\(String(format: "%.1f", self.duration)) quality=\(self.currentQuality ?? -99) switching=\(self.isSwitching) cache=\(self.core?.getString("demuxer-cache-duration").flatMap(Double.init).map { String(format: "%.0f", $0) } ?? "-") vid=\(self.core?.getString("vid") ?? "-") vo=\(self.core?.getString("current-vo") ?? "-") hw=\(self.core?.getString("hwdec-current") ?? "-") mpv=\(self.core?.getString("time-pos") ?? "nil")")
            }
        }
    }
    #endif

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[MPVPlayer] \(message())")
        #endif
    }

    // MARK: - Decoder recovery

    /// iOS may end VideoToolbox decoding when the app goes to the background, the screen locks or memory
    /// runs low; the layer then fails and the picture stays black (also in Picture in Picture). Restart
    /// the decoder – a few times at most, after that mpv stays on software decoding (as Streamyfin does).
    private func observeLayerStatus() {
        layerStatusObservation = layer.observe(\.status, options: [.new]) { [weak self] layer, _ in
            guard layer.status == .failed else { return }
            Task { @MainActor in self?.recoverDecoder() }
        }
    }

    private func recoverDecoder() {
        guard let core, decoderResets < 3 else { return }
        decoderResets += 1
        debugLog("display layer failed, resetting decoder (\(decoderResets)/3)")
        if layer.requiresFlushToResumeDecoding { layer.flush() }
        core.setString("hwdec", "no")
        if decoderResets < 3 { core.setString("hwdec", MPVCore.hardwareDecoding) }
    }
}
