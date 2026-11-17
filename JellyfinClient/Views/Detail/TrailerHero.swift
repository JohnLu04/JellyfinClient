import AVFoundation
import SwiftUI
import WebKit

enum TrailerSource: Equatable {
    case youtube(id: String)
    case file(URL)
}

/// Picks the trailer for the title page's play button, preferring German ones:
/// German YouTube trailer → German local trailer → any YouTube trailer → any local trailer.
///
/// Jellyfin fetches remote trailers from TMDb in the library's metadata language,
/// so with German metadata most remote trailers are German already.
enum TrailerPicker {
    private static let germanHints = ["deutsch", "german", "(de)", "[de]", " de ", " ger ", " dt.", " dt "]
    private static let germanLanguages: Set<String> = ["ger", "deu", "de", "german", "deutsch"]

    static func isGerman(_ name: String?) -> Bool {
        let text = " " + (name ?? "").lowercased().replacingOccurrences(of: "-", with: " ") + " "
        return germanHints.contains { text.contains($0) }
    }

    static func youTubeID(from urlString: String?) -> String? {
        guard let urlString, let comps = URLComponents(string: urlString), let host = comps.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            return comps.path.split(separator: "/").first.map(String.init)
        }
        guard host.contains("youtube") else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = comps.path.split(separator: "/")
        if let index = parts.firstIndex(where: { $0 == "embed" || $0 == "shorts" }), index + 1 < parts.count {
            return String(parts[index + 1])
        }
        return nil
    }

    static func pick(for item: BaseItem, api: JellyfinAPI) async -> TrailerSource? {
        let remote = (item.remoteTrailers ?? []).compactMap { trailer in
            youTubeID(from: trailer.url).map { (trailer, $0) }
        }
        var locals: [BaseItem] = []
        if (item.localTrailerCount ?? 0) > 0 {
            locals = (try? await api.localTrailers(itemId: item.id)) ?? []
        }
        let germanLocal = locals.first { trailer in
            isGerman(trailer.name) || (trailer.primaryMediaSource?.audioStreams ?? []).contains {
                germanLanguages.contains(($0.language ?? "").lowercased())
            }
        }

        if let german = remote.first(where: { isGerman($0.0.name) }) { return .youtube(id: german.1) }
        if let germanLocal, let url = await streamURL(for: germanLocal, api: api) { return .file(url) }
        if let any = remote.first { return .youtube(id: any.1) }
        if let anyLocal = locals.first, let url = await streamURL(for: anyLocal, api: api) { return .file(url) }
        return nil
    }

    private static func streamURL(for trailer: BaseItem, api: JellyfinAPI) async -> URL? {
        try? await PlaybackResolver.resolve(item: trailer, api: api, maxMbit: 0,
                                            selection: TrackSelection(), player: .native).url
    }
}

/// Header artwork with a play button when the title has a trailer (like streaming apps). The trailer
/// only starts when the button is tapped, with sound; tapping the video pauses it and brings the
/// artwork and the button back. When it ends, the artwork returns and the button plays it again.
struct TrailerHero: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKeys.autoplayTrailers) private var showTrailers = true
    @Environment(\.scenePhase) private var scenePhase

    let item: BaseItem
    let topInset: CGFloat

    @State private var source: TrailerSource?
    /// The trailer's player exists (the play button was tapped and it hasn't ended or been stopped).
    @State private var isStarted = false
    /// The trailer runs and is shown over the artwork.
    @State private var isPlaying = false
    /// Paused by a tap or by the app going to the background: the artwork and the play button show.
    @State private var isPaused = false
    /// The viewer's choice; the trailer only makes sound while its picture shows.
    @State private var isMuted = false
    /// A new player for each start, so a trailer that ended plays from the beginning again.
    @State private var run = 0

    private var showsVideo: Bool { isStarted && isPlaying && !isPaused }
    /// No sound while the artwork still covers the video (loading, YouTube's overlay, paused).
    private var playsMuted: Bool { isMuted || !showsVideo }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: app.api?.heroBackdropURL(for: item), placeholderSymbol: "film")
                    .frame(width: geo.size.width, height: geo.size.height)

                if let source, isStarted {
                    trailerView(source)
                        .id(run)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(showsVideo ? 1 : 0)
                        .animation(.easeInOut(duration: 0.5), value: showsVideo)
                        .allowsHitTesting(false)
                }

                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset + 60)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)

                centerControl
                    .frame(width: geo.size.width, height: max(0, geo.size.height - topInset))
                    .frame(maxHeight: .infinity, alignment: .bottom)

                if showsVideo {
                    Button {
                        isMuted.toggle()
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(isMuted ? "Unmute trailer" : "Mute trailer")
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .clipped()
        }
        // Items opened from lists don't carry trailer info yet; re-run once the full item has loaded.
        .task(id: trailerInfoKey) { await loadTrailer() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackWillStart)) { _ in stopTrailer() }
        .onDisappear { stopTrailer() }
        .onChange(of: scenePhase) { _, phase in
            // iOS pauses the trailer in the background; it continues with a tap on the play button.
            if phase == .background, isStarted { pause() }
        }
    }

    /// The play button over the artwork, a spinner while the trailer loads, or (while it runs) a
    /// clear area that pauses it on a tap.
    @ViewBuilder
    private var centerControl: some View {
        if showsVideo {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { pause() }
                .accessibilityElement()
                .accessibilityLabel("Pause Trailer")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { pause() }
        } else if isStarted && !isPaused {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .shadow(color: .black.opacity(0.5), radius: 6)
                .allowsHitTesting(false)
        } else if source != nil && showTrailers {
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 2)
                    .frame(width: 66, height: 66)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play Trailer")
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func trailerView(_ source: TrailerSource) -> some View {
        switch source {
        case let .youtube(id):
            // YouTube shows its own overlay (title, "More videos") for the first seconds of playing;
            // the player reports when the video has played long enough for it to be gone.
            YouTubeTrailerView(videoID: id, muted: playsMuted, paused: isPaused,
                               onVisible: reveal, onEnded: finish,
                               onForcedMute: { isMuted = true })
        case let .file(url):
            FileTrailerView(url: url, muted: playsMuted, paused: isPaused,
                            onPlaying: reveal, onEnded: finish)
        }
    }

    private var trailerInfoKey: String {
        "\(item.id)|\(item.remoteTrailers?.count ?? -1)|\(item.localTrailerCount ?? -1)"
    }

    /// Looks up the trailer right away, so the play button shows; nothing plays until it is tapped.
    private func loadTrailer() async {
        guard showTrailers, source == nil, let api = app.api else { return }
        guard item.remoteTrailers != nil || item.localTrailerCount != nil else { return }   // wait for the full item
        let picked = await TrailerPicker.pick(for: item, api: api)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.3)) { source = picked }
        #if DEBUG
        NSLog("[Trailer] %@", "\(item.name ?? item.id): \(source.map { "\($0)" } ?? "none")")
        #endif
    }

    private func play() {
        if isStarted {
            isPaused = false            // continue where it was paused
            return
        }
        isMuted = false
        isPaused = false
        isPlaying = false
        run += 1
        isStarted = true
    }

    /// Shows the running trailer over the artwork; its sound comes on with it.
    private func reveal() {
        guard isStarted, !isPaused else { return }
        isPlaying = true
    }

    /// Pauses the trailer and brings back the artwork with the play button.
    private func pause() {
        isPaused = true
        isPlaying = false
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.5)) { stopTrailer() }
    }

    /// Removes the player and shows the artwork with the play button again.
    private func stopTrailer() {
        isStarted = false
        isPlaying = false
        isPaused = false
    }
}

// MARK: - YouTube (embedded player in a web view, inline)

struct YouTubeTrailerView: UIViewRepresentable {
    let videoID: String
    let muted: Bool
    /// True while the app is in the background; going back to false resumes the trailer.
    let paused: Bool
    /// The video has played a few seconds, so YouTube's own overlay has faded out.
    let onVisible: () -> Void
    let onEnded: () -> Void
    /// iOS may refuse to resume with sound without a tap; the trailer then continues muted.
    let onForcedMute: () -> Void

    /// YouTube requires a valid https origin/referrer for embedded playback.
    private static let origin = "https://jellyfin-client.app"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.userContentController.add(context.coordinator, name: "trailer")
        context.coordinator.html = html

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.update(onVisible: onVisible, onEnded: onEnded, onForcedMute: onForcedMute)
        context.coordinator.muted = muted
        context.coordinator.paused = paused
        webView.loadHTMLString(html, baseURL: URL(string: Self.origin))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(onVisible: onVisible, onEnded: onEnded, onForcedMute: onForcedMute)
        if context.coordinator.muted != muted {
            context.coordinator.muted = muted
            webView.evaluateJavaScript("setMuted(\(muted))")
        }
        if context.coordinator.paused != paused {
            context.coordinator.paused = paused
            webView.evaluateJavaScript(paused ? "pauseTrailer()" : "resumeTrailer()")
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "trailer")
        webView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var muted = true
        var paused = false
        var html = ""
        private var onVisible: (() -> Void)?
        private var onEnded: (() -> Void)?
        private var onForcedMute: (() -> Void)?

        func update(onVisible: @escaping () -> Void, onEnded: @escaping () -> Void, onForcedMute: @escaping () -> Void) {
            self.onVisible = onVisible
            self.onEnded = onEnded
            self.onForcedMute = onForcedMute
        }

        /// iOS can end the web view's process while the app is in the background; start the trailer again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.loadHTMLString(html, baseURL: URL(string: YouTubeTrailerView.origin))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            #if DEBUG
            NSLog("[Trailer] %@", "youtube \(body)")
            #endif
            if body["forcedMute"] != nil {
                muted = true
                onForcedMute?()
            } else if body["visible"] != nil {
                onVisible?()
            } else if let state = body["state"] as? Int {
                if state == 0 { onEnded?() }         // ended
            } else if body["error"] != nil {
                onEnded?()                           // e.g. embedding disabled → keep the artwork
            }
        }
    }

    private var html: String {
        """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
          html,body{margin:0;padding:0;background:#000;overflow:hidden;width:100%;height:100%}
          #player{position:absolute;top:50%;left:50%;width:100vw;height:56.25vw;min-height:100vh;min-width:177.78vh;
                  transform:translate(-50%,-50%);pointer-events:none;border:0}
        </style></head><body>
        <div id="player"></div>
        <script>
          var player;
          function post(m){ try{ window.webkit.messageHandlers.trailer.postMessage(m) }catch(e){} }
          window.onerror = function(msg){ post({log: String(msg)}); };
          // YouTube's title bar and "More videos" button show during the first seconds of playing and
          // right after a pause: report the video as visible once it has played past them.
          var revealAt = null;
          setInterval(function(){
            if(revealAt===null||!player||!player.getCurrentTime||player.getPlayerState()!==1){ return }
            if(player.getCurrentTime() >= revealAt){ revealAt = null; post({visible:true}); }
          }, 200);
          var appPaused = false;
          function setMuted(m){
            if(!player||!player.mute){return}
            if(m){ player.mute(); return }
            player.unMute(); player.setVolume(100);
            // Sound can be blocked without a tap, which stops the video: continue muted instead.
            setTimeout(function(){
              if(!appPaused && player.getPlayerState() === 2 && !player.isMuted()){
                player.mute(); post({forcedMute:true}); player.playVideo();
              }
            }, 1500);
          }
          function pauseTrailer(){ appPaused = true; revealAt = null; if(player&&player.pauseVideo){ player.pauseVideo() } }
          function resumeTrailer(){
            if(!player||!player.playVideo){ return }
            appPaused = false;
            revealAt = (player.getCurrentTime ? player.getCurrentTime() : 0) + 2.5;
            player.playVideo();
            // Resuming with sound can be blocked without a tap: continue muted instead of staying paused.
            setTimeout(function(){
              if(player.getPlayerState && player.getPlayerState() !== 1 && !player.isMuted()){
                player.mute(); post({forcedMute:true}); player.playVideo();
              }
            }, 1500);
          }
          function onYouTubeIframeAPIReady(){
            player = new YT.Player('player', {
              videoId: '\(videoID)',
              host: 'https://www.youtube-nocookie.com',
              playerVars: { autoplay:1, mute:\(muted ? 1 : 0), controls:0, playsinline:1, rel:0, iv_load_policy:3, fs:0,
                            disablekb:1, modestbranding:1, cc_load_policy:0, hl:'de', origin:'\(Self.origin)' },
              events: {
                onReady: function(e){ setMuted(\(muted)); revealAt = 3.5; e.target.playVideo(); },
                onStateChange: function(e){ post({state:e.data}); },
                onError: function(e){ post({error:e.data}); }
              }
            });
          }
          var tag = document.createElement('script');
          tag.src = 'https://www.youtube.com/iframe_api';
          document.body.appendChild(tag);
        </script></body></html>
        """
    }
}

// MARK: - Local trailer files (served by Jellyfin)

struct FileTrailerView: UIViewRepresentable {
    let url: URL
    let muted: Bool
    /// True while the app is in the background; going back to false resumes the trailer.
    let paused: Bool
    let onPlaying: () -> Void
    let onEnded: () -> Void

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator {
        var player: AVPlayer?
        var paused = false
        var ended = false
        var statusObservation: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        let player = AVPlayer(url: url)
        player.isMuted = muted
        player.preventsDisplaySleepDuringVideoPlayback = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill

        let onPlaying = onPlaying
        let onEnded = onEnded
        context.coordinator.player = player
        context.coordinator.statusObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            if player.timeControlStatus == .playing { DispatchQueue.main.async { onPlaying() } }
        }
        context.coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [coordinator = context.coordinator] _ in
                coordinator.ended = true
                onEnded()
            }
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.player?.isMuted = muted
        if coordinator.paused != paused {
            coordinator.paused = paused
            if paused {
                coordinator.player?.pause()
            } else if !coordinator.ended {
                coordinator.player?.play()
            }
        }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.statusObservation = nil
        if let observer = coordinator.endObserver { NotificationCenter.default.removeObserver(observer) }
        view.playerLayer.player = nil
    }
}
