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

final class MPVLayerHostView: UIView {
    weak var controller: MPVPlayerController?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let controller else { return }
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controller.layer.frame = bounds
        controller.layer.contentsScale = scale
        // Once MoltenVK has created its swapchain the layer no longer resizes its drawable by itself.
        // mpv reads the drawable size to size its output, so set it explicitly (e.g. after rotating),
        // otherwise the old portrait-sized picture ends up in a corner of the landscape screen.
        if bounds.width > 1 && bounds.height > 1 {
            controller.layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
        CATransaction.commit()
        controller.updateSubtitleScale(for: bounds.size)
        controller.renderSizeChanged(to: bounds.size)
        if bounds.width > 1 && bounds.height > 1 { controller.startIfNeeded() }
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The show/hide tap lives on the video only, so it never competes with the menus and buttons on top.
            MPVVideoView(controller: controller)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if (controller.isBuffering || controller.isSwitching) && controller.errorMessage == nil {
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

            if let error = controller.errorMessage {
                errorView(error)
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { scheduleHide() }
        .onChange(of: controller.isPaused) { scheduleHide() }
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
struct MPVScrubBar: View {
    let controller: MPVPlayerController
    let onScrubbing: (Bool) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        let shown = isDragging ? dragValue : controller.position
        let duration = max(controller.duration, 1)
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { min(shown, duration) },
                    set: { value in
                        if isDragging {
                            dragValue = value
                        } else {
                            // A tap on the track changes the value without a drag: seek right away.
                            controller.seek(to: value)
                        }
                    }),
                in: 0...duration
            ) { editing in
                if editing {
                    dragValue = controller.position
                    isDragging = true
                    onScrubbing(true)
                } else {
                    controller.seek(to: dragValue)
                    isDragging = false
                    onScrubbing(false)
                }
            }
            .tint(.white)

            HStack {
                Text(Self.timeText(shown))
                Spacer()
                Text("−" + Self.timeText(max(controller.duration - shown, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        Ticks.clockText(Ticks.ticks(seconds.isFinite ? seconds : 0))
    }
}
