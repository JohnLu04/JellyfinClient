import AVFoundation
import SwiftUI
import WebKit

enum TrailerSource: Equatable {
    case youtube(id: String)
    case file(URL)
}

/// Picks the trailer to autoplay, preferring German ones:
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

/// Header artwork that turns into a muted, inline trailer after a moment (like streaming apps).
struct TrailerHero: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKeys.autoplayTrailers) private var autoplayTrailers = true

    let item: BaseItem
    let topInset: CGFloat

    @State private var source: TrailerSource?
    @State private var isPlaying = false
    @State private var isMuted = true
    @State private var isFinished = false
    @State private var isActive = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: app.api?.heroBackdropURL(for: item), placeholderSymbol: "film")
                    .frame(width: geo.size.width, height: geo.size.height)

                if let source, isActive, !isFinished {
                    trailerView(source)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(isPlaying ? 1 : 0)
                        .animation(.easeInOut(duration: 0.6), value: isPlaying)
                        .allowsHitTesting(false)
                }

                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset + 60)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)

                if isPlaying && !isFinished && isActive {
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
    }

    @ViewBuilder
    private func trailerView(_ source: TrailerSource) -> some View {
        switch source {
        case let .youtube(id):
            // YouTube shows its own overlay for the first seconds; reveal the video once that's gone.
            YouTubeTrailerView(videoID: id, muted: isMuted,
                               onPlaying: { reveal(after: .seconds(2.5)) }, onEnded: finish)
        case let .file(url):
            FileTrailerView(url: url, muted: isMuted,
                            onPlaying: { reveal(after: .zero) }, onEnded: finish)
        }
    }

    private var trailerInfoKey: String {
        "\(item.id)|\(item.remoteTrailers?.count ?? -1)|\(item.localTrailerCount ?? -1)"
    }

    private func loadTrailer() async {
        guard autoplayTrailers, source == nil, !isFinished, let api = app.api else { return }
        guard item.remoteTrailers != nil || item.localTrailerCount != nil else { return }   // wait for the full item
        // Let the page settle (and avoid loading trailers while scrolling past quickly).
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled else { return }
        source = await TrailerPicker.pick(for: item, api: api)
        #if DEBUG
        NSLog("[Trailer] %@", "\(item.name ?? item.id): \(source.map { "\($0)" } ?? "none")")
        #endif
    }

    private func reveal(after delay: Duration) {
        guard !isPlaying else { return }
        Task {
            try? await Task.sleep(for: delay)
            guard isActive, !isFinished else { return }
            isPlaying = true
        }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.6)) {
            isPlaying = false
            isFinished = true
        }
    }

    private func stopTrailer() {
        isActive = false
        isPlaying = false
        isFinished = true
    }
}

// MARK: - YouTube (embedded player in a web view, inline and muted)

struct YouTubeTrailerView: UIViewRepresentable {
    let videoID: String
    let muted: Bool
    let onPlaying: () -> Void
    let onEnded: () -> Void

    /// YouTube requires a valid https origin/referrer for embedded playback.
    private static let origin = "https://jellyfin-client.app"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.userContentController.add(context.coordinator, name: "trailer")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        context.coordinator.update(onPlaying: onPlaying, onEnded: onEnded)
        context.coordinator.muted = muted
        webView.loadHTMLString(html, baseURL: URL(string: Self.origin))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(onPlaying: onPlaying, onEnded: onEnded)
        if context.coordinator.muted != muted {
            context.coordinator.muted = muted
            webView.evaluateJavaScript("setMuted(\(muted))")
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "trailer")
        webView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var muted = true
        private var onPlaying: (() -> Void)?
        private var onEnded: (() -> Void)?

        func update(onPlaying: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onPlaying = onPlaying
            self.onEnded = onEnded
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            #if DEBUG
            NSLog("[Trailer] %@", "youtube \(body)")
            #endif
            if let state = body["state"] as? Int {
                if state == 1 { onPlaying?() }       // playing
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
          function setMuted(m){ if(!player||!player.mute){return} if(m){player.mute()}else{player.unMute();player.setVolume(100)} }
          function onYouTubeIframeAPIReady(){
            player = new YT.Player('player', {
              videoId: '\(videoID)',
              host: 'https://www.youtube-nocookie.com',
              playerVars: { autoplay:1, mute:1, controls:0, playsinline:1, rel:0, iv_load_policy:3, fs:0,
                            disablekb:1, modestbranding:1, cc_load_policy:0, hl:'de', origin:'\(Self.origin)' },
              events: {
                onReady: function(e){ e.target.mute(); e.target.playVideo(); },
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
    let onPlaying: () -> Void
    let onEnded: () -> Void

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator {
        var player: AVPlayer?
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
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in onEnded() }
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        context.coordinator.player?.isMuted = muted
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.statusObservation = nil
        if let observer = coordinator.endObserver { NotificationCenter.default.removeObserver(observer) }
        view.playerLayer.player = nil
    }
}
