import SwiftUI

/// The download button while a download runs: a thin ring that fills up in red, clockwise from the
/// top. Paused it turns grey with a pause sign in the middle; waiting in the queue it stays grey.
struct DownloadProgressRing: View {
    enum Mode { case loading, waiting, paused }

    let progress: Double
    var mode: Mode = .loading
    var size: CGFloat = 26
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.3), lineWidth: lineWidth)
            Circle()
                // A sliver right away, so a download that just started is visibly running.
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(mode == .loading ? Color.accentColor : Color.primary.opacity(0.75),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
            if mode == .paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let percent = Int(progress * 100)
        switch mode {
        case .loading: return String(localized: "Downloading · \(percent) %")
        case .waiting: return String(localized: "Download Queued")
        case .paused: return String(localized: "Paused · \(percent) %")
        }
    }
}

extension DownloadRecord {
    /// How the download button's ring looks, or nil when it shows no ring (finished, failed).
    var ringMode: DownloadProgressRing.Mode? {
        switch state {
        case .downloading: .loading
        case .queued: .waiting
        case .paused: .paused
        case .completed, .failed: nil
        }
    }
}
