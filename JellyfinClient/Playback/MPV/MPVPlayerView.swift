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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controller.layer.frame = bounds
        controller.layer.contentsScale = traitCollection.displayScale
        CATransaction.commit()
        controller.updateSubtitleScale(for: bounds.size)
        if bounds.width > 1 && bounds.height > 1 { controller.startIfNeeded() }
    }
}

struct MPVPlayerView: View {
    let controller: MPVPlayerController
    let onClose: () -> Void

    @State private var showControls = true
    @State private var scrubPosition: Double?
    @State private var hideTask: Task<Void, Never>?

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
                audioMenu
                subtitleMenu
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

            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { scrubPosition ?? controller.position },
                                   set: { scrubPosition = $0 }),
                    in: 0...max(controller.duration, 1)
                ) { editing in
                    if editing {
                        hideTask?.cancel()
                    } else {
                        if let target = scrubPosition { controller.seek(to: target) }
                        scrubPosition = nil
                        scheduleHide()
                    }
                }
                .tint(.white)
                HStack {
                    Text(timeText(scrubPosition ?? controller.position))
                    Spacer()
                    Text("−" + timeText(max(controller.duration - (scrubPosition ?? controller.position), 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
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

    private var audioMenu: some View {
        Menu {
            Picker("Audio", selection: Binding(
                get: { controller.selectedAudio ?? -1 },
                set: { controller.selectAudio($0); scheduleHide() }
            )) {
                ForEach(controller.audioOptions) { option in
                    Text(option.label).tag(option.id)
                }
            }
        } label: {
            menuLabel("waveform.circle", text: "Audio")
        }
        .disabled(controller.audioOptions.isEmpty || controller.isSwitching)
    }

    private var subtitleMenu: some View {
        Menu {
            Picker("Subtitles", selection: Binding(
                get: { controller.selectedSubtitle ?? -1 },
                set: { controller.selectSubtitle($0 < 0 ? nil : $0); scheduleHide() }
            )) {
                Text("Off").tag(-1)
                ForEach(controller.subtitleOptions) { option in
                    Text(option.label).tag(option.id)
                }
            }
        } label: {
            menuLabel(controller.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill", text: "Subtitles")
        }
        .disabled(controller.subtitleOptions.isEmpty || controller.isSwitching)
    }

    private func menuLabel(_ symbol: String, text: LocalizedStringKey) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .accessibilityLabel(text)
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
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard showControls else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !controller.isPaused, scrubPosition == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        Ticks.clockText(Ticks.ticks(seconds.isFinite ? seconds : 0))
    }
}
