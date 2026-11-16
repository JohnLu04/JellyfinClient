import AVFoundation
import SwiftUI
import UIKit

/// Hosts mpv's Metal layer and starts mpv once the view has a real size.
struct MPVVideoView: UIViewRepresentable {
    let controller: MPVPlayerController

    func makeUIView(context: Context) -> MPVLayerHostView {
        let view = MPVLayerHostView()
        view.backgroundColor = .black
        view.controller = controller
        view.layer.addSublayer(controller.layer)
        return view
    }

    func updateUIView(_ uiView: MPVLayerHostView, context: Context) {}
}

/// Shows mpv's Metal layer.
///
/// mpv's iOS output only picks up a new surface size when it rebuilds its video output, which would
/// interrupt playback on every rotation. So mpv always renders into a fixed surface: the video's aspect
/// ratio at the screen's full landscape resolution. Fitting it into the view is done with a scale
/// transform, which Core Animation animates together with the rotation – mpv never notices.
final class MPVLayerHostView: UIView {
    weak var controller: MPVPlayerController? {
        didSet {
            controller?.onVideoAspectChange = { [weak self] in
                self?.setNeedsLayout()
                self?.layoutIfNeeded()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let controller, bounds.width > 1, bounds.height > 1 else { return }
        let metal = controller.layer
        let screen = window?.windowScene?.screen
        let scale = screen?.nativeScale ?? traitCollection.displayScale
        let surface = Self.surfaceSize(aspect: controller.videoAspect, screen: screen, scale: scale)

        // The surface itself never animates: a new size only happens before or right at the start.
        if metal.bounds.size != surface.points {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metal.contentsScale = scale
            metal.bounds = CGRect(origin: .zero, size: surface.points)
            metal.drawableSize = surface.pixels
            CATransaction.commit()
        }

        // Follow the rotation animation, if one is running, so the picture turns smoothly with the screen.
        let fit = min(bounds.width / surface.points.width, bounds.height / surface.points.height)
        let running = layer.animation(forKey: "bounds.size") ?? layer.animation(forKey: "bounds")
        CATransaction.begin()
        if let running {
            CATransaction.setAnimationDuration(running.duration)
            CATransaction.setAnimationTimingFunction(running.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        metal.position = CGPoint(x: bounds.midX, y: bounds.midY)
        metal.setAffineTransform(CGAffineTransform(scaleX: fit, y: fit))
        CATransaction.commit()

        controller.startIfNeeded()
    }

    /// The video's aspect ratio fitted into the screen's landscape pixel size.
    private static func surfaceSize(aspect: Double, screen: UIScreen?, scale: CGFloat) -> (points: CGSize, pixels: CGSize) {
        let native = screen?.nativeBounds.size ?? CGSize(width: 1080, height: 1920)
        let long = max(native.width, native.height)
        let short = min(native.width, native.height)
        var width = long
        var height = (long / aspect).rounded()
        if height > short {
            height = short
            width = (short * aspect).rounded()
        }
        let pixels = CGSize(width: max(width, 2), height: max(height, 2))
        return (CGSize(width: pixels.width / scale, height: pixels.height / scale), pixels)
    }
}

struct MPVPlayerView: View {
    let controller: MPVPlayerController
    let onClose: () -> Void

    @State private var showControls = true
    @State private var isScrubbing = false
    /// True while the user is in a track menu, so the controls (and the open menu) don't auto-hide.
    @State private var holdControls = false
    @State private var hideTask: Task<Void, Never>?
    @State private var showTracks = false
    @State private var showQuality = false
    @State private var showStats = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The show/hide tap lives on the video only, so it never competes with the menus and buttons on top.
            MPVVideoView(controller: controller)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            // Apple's player during the hand-over to Picture in Picture (transparent otherwise).
            PiPLayerView(layer: controller.pictureInPicture.playerLayer)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if (controller.isBuffering || controller.isSwitching || controller.pipState == .preparing) && controller.errorMessage == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .allowsHitTesting(false)
            }

            if showControls || controller.errorMessage != nil {
                controls
                    .transition(.opacity)
            }

            if showTracks && controller.errorMessage == nil {
                tracksPanel
            }

            if showStats && controller.errorMessage == nil {
                MPVStatsPanel(controller: controller, onClose: closeStats)
                    .transition(.opacity)
            }

            if let error = controller.errorMessage {
                errorView(error)
            }

            // Also over a playback error: a lower quality is often the way out.
            if showQuality {
                qualityPanel
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            scheduleHide()
            #if DEBUG
            if ProcessInfo.processInfo.environment["JF_DEBUG_SHOW_QUALITY"] != nil { showQuality = true; holdControls = true }
            #endif
        }
        .onChange(of: controller.isPaused) { scheduleHide() }
        .alert("Picture in Picture", isPresented: Binding(
            get: { controller.pipMessage != nil },
            set: { if !$0 { controller.pipMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.pipMessage ?? "")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                circleButton("xmark", label: "Close", action: onClose)
                Text(controller.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if MPVPictureInPicture.isSupported {
                    pipButton
                }
                statsButton
                tracksButton
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 44) {
                transportButton("gobackward.10", size: 30) { controller.skip(by: -10) }
                transportButton(controller.isPaused ? "play.fill" : "pause.fill", size: 46) { controller.togglePause() }
                transportButton("goforward.10", size: 30) { controller.skip(by: 10) }
            }
            .opacity(controller.isSwitching ? 0.4 : 1)

            Spacer()

            if controller.currentQuality != nil {
                HStack {
                    Spacer()
                    qualityButton
                }
                .padding(.horizontal)
            }

            // Separate view: only the seek bar re-renders as the time advances, not the menus above.
            MPVScrubBar(controller: controller) { scrubbing in
                isScrubbing = scrubbing
                if scrubbing { hideTask?.cancel() } else { scheduleHide() }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .background {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    /// One large button for both track lists. A plain Button opens our own panel: SwiftUI `Menu`s
    /// inside the auto-hiding overlay often swallowed taps or closed again right away.
    private var tracksButton: some View {
        Button {
            hideTask?.cancel()
            holdControls = true
            withAnimation(.easeOut(duration: 0.2)) { showTracks = true }
        } label: {
            Image(systemName: controller.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Audio & Subtitles")
        .disabled((controller.audioOptions.isEmpty && controller.subtitleOptions.isEmpty) || controller.isSwitching)
    }

    /// Hands the video to Picture in Picture.
    private var pipButton: some View {
        Button {
            hideTask?.cancel()
            controller.startPictureInPicture()
        } label: {
            Image(systemName: "pip.enter")
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Picture in Picture")
        .disabled(controller.pipState != .idle || controller.isSwitching || controller.duration <= 0)
    }

    /// Opens the live "Video Details" panel (bitrate, buffer, file size, codecs …).
    private var statsButton: some View {
        Button {
            hideTask?.cancel()
            holdControls = true
            withAnimation(.easeOut(duration: 0.2)) { showStats = true }
        } label: {
            Image(systemName: "info.circle")
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Video Details")
    }

    /// Shows the current streaming quality; opens the list to change it while the video plays.
    private var qualityButton: some View {
        Button {
            hideTask?.cancel()
            holdControls = true
            withAnimation(.easeOut(duration: 0.2)) { showQuality = true }
        } label: {
            Label(controller.currentQuality.map(Bitrate.label) ?? "", systemImage: "gauge.with.dots.needle.67percent")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.ultraThinMaterial, in: Capsule())
                .contentShape(Capsule())
        }
        .accessibilityLabel("Quality")
        .accessibilityValue(controller.currentQuality.map(Bitrate.label) ?? "")
        .disabled(controller.isSwitching || controller.pipState != .idle)
    }

    private var qualityPanel: some View {
        let choices = controller.qualityChoices
        return ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { closeQuality() }

            VStack(spacing: 0) {
                HStack {
                    Text("Quality")
                        .font(.headline)
                    Spacer()
                    Button("Done") { closeQuality() }
                        .font(.headline)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider().overlay(.white.opacity(0.2))

                trackColumn("Streaming quality",
                            options: choices.enumerated().map { index, mbit in (index, qualityLabel(mbit)) },
                            selected: controller.currentQuality.flatMap { current in choices.firstIndex(of: current) }) { index in
                    controller.selectQuality(choices[index])
                    closeQuality()
                }

                Text("The video continues where it is; a new quality takes a moment to load.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 420, maxHeight: 520)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .environment(\.colorScheme, .dark)
            .padding(16)
        }
        .transition(.opacity)
    }

    private func qualityLabel(_ mbit: Double) -> String {
        if mbit == 0, let source = controller.sourceMbit {
            return Bitrate.label(0) + " · " + source.formatted(.number.precision(.fractionLength(1))) + " Mbit/s"
        }
        return Bitrate.label(mbit)
    }

    private func closeQuality() {
        withAnimation(.easeOut(duration: 0.2)) { showQuality = false }
        holdControls = false
        scheduleHide()
    }

    private var tracksPanel: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { closeTracks() }

            VStack(spacing: 0) {
                HStack {
                    Text("Audio & Subtitles")
                        .font(.headline)
                    Spacer()
                    Button("Done") { closeTracks() }
                        .font(.headline)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider().overlay(.white.opacity(0.2))

                HStack(alignment: .top, spacing: 0) {
                    trackColumn("Audio",
                                options: controller.audioOptions.map { ($0.id, $0.label) },
                                selected: controller.selectedAudio) { controller.selectAudio($0) }
                    Divider().overlay(.white.opacity(0.2))
                    trackColumn("Subtitles",
                                options: [(-1, String(localized: "Off"))] + controller.subtitleOptions.map { ($0.id, $0.label) },
                                selected: controller.selectedSubtitle ?? -1) { id in
                        controller.selectSubtitle(id < 0 ? nil : id)
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 640, maxHeight: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .environment(\.colorScheme, .dark)
            .padding(16)
        }
        .transition(.opacity)
    }

    private func trackColumn(_ title: LocalizedStringKey, options: [(Int, String)], selected: Int?,
                             onSelect: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options, id: \.0) { id, label in
                        Button {
                            guard id != selected else { return }
                            onSelect(id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .opacity(id == selected ? 1 : 0)
                                Text(label)
                                    .multilineTextAlignment(.leading)
                                    .fontWeight(id == selected ? .semibold : .regular)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.isSwitching)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circleButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 30, height: size + 30)
                .contentShape(Rectangle())
        }
        .disabled(controller.isSwitching)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(message)
                .multilineTextAlignment(.center)
            Button("Close", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    // MARK: - Helpers

    private func toggleControls() {
        holdControls = false
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        scheduleHide()
    }

    private func closeStats() {
        withAnimation(.easeOut(duration: 0.2)) { showStats = false }
        holdControls = false
        scheduleHide()
    }

    private func closeTracks() {
        withAnimation(.easeOut(duration: 0.2)) { showTracks = false }
        holdControls = false
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard showControls else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !controller.isPaused, !isScrubbing, !holdControls else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }
}

/// Seek bar with elapsed/remaining time. Lives in its own view so the frequent time updates
/// only redraw this bar.
///
/// A custom bar instead of SwiftUI's `Slider`: the slider reports the end of a drag through
/// `onEditingChanged(false)`, which never comes when iOS cancels the touch (the bar sits right above
/// the Home indicator, whose system gesture takes over swipes there). The bar then stayed frozen on the
/// dragged time and the controls never hid again. A gesture state resets by itself when the gesture
/// ends or is cancelled, so the bar always follows playback again.
struct MPVScrubBar: View {
    let controller: MPVPlayerController
    let onScrubbing: (Bool) -> Void

    /// The dragged-to fraction (0...1) while a finger is on the bar; nil otherwise.
    @GestureState private var dragFraction: Double?

    var body: some View {
        let duration = max(controller.duration, 1)
        let shown = dragFraction.map { $0 * duration } ?? min(max(controller.position, 0), duration)
        let isDragging = dragFraction != nil
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let fraction = shown / duration
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: isDragging ? 8 : 4)
                    Capsule()
                        .fill(.white)
                        .frame(width: max(width * fraction, 0), height: isDragging ? 8 : 4)
                    Circle()
                        .fill(.white)
                        .frame(width: isDragging ? 22 : 14, height: isDragging ? 22 : 14)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .offset(x: min(max(width * fraction - (isDragging ? 11 : 7), -4), width - (isDragging ? 18 : 10)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragFraction) { value, state, _ in
                            state = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            // Also a plain tap: jump to where the bar was touched.
                            controller.seek(to: min(max(value.location.x / width, 0), 1) * duration)
                        }
                )
                .animation(.easeOut(duration: 0.15), value: isDragging)
            }
            .frame(height: 30)

            HStack {
                Text(Self.timeText(shown))
                Spacer()
                Text("−" + Self.timeText(max(controller.duration - shown, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .onChange(of: isDragging) { _, dragging in onScrubbing(dragging) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback Position")
        .accessibilityValue(Self.timeText(shown))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.skip(by: 10)
            case .decrement: controller.skip(by: -10)
            @unknown default: break
            }
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        Ticks.clockText(Ticks.ticks(seconds.isFinite ? seconds : 0))
    }
}

/// Live playback details over the video, refreshed every second while open.
struct MPVStatsPanel: View {
    let controller: MPVPlayerController
    let onClose: () -> Void

    @State private var sections: [PlaybackStatsSection] = []

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                HStack {
                    Text("Video Details")
                        .font(.headline)
                    Spacer()
                    Button("Done", action: onClose)
                        .font(.headline)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider().overlay(.white.opacity(0.2))

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                                ForEach(section.rows) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(row.label)
                                            .foregroundStyle(.white.opacity(0.8))
                                        Spacer(minLength: 8)
                                        Text(row.value)
                                            .fontWeight(.medium)
                                            .monospacedDigit()
                                            .multilineTextAlignment(.trailing)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 520, maxHeight: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .environment(\.colorScheme, .dark)
            .padding(16)
        }
        .task {
            while !Task.isCancelled {
                sections = controller.readStats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Holds the AVPlayerLayer used for the Picture in Picture hand-over, sized to the screen.
struct PiPLayerView: UIViewRepresentable {
    let layer: AVPlayerLayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.playerLayer = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}

    final class LayerView: UIView {
        var playerLayer: AVPlayerLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
