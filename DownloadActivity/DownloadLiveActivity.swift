import ActivityKit
import SwiftUI
import WidgetKit

/// Download progress on the Lock Screen (poster, title, progress bar, size and speed) and in the
/// Dynamic Island.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PosterView(data: state.poster, width: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PercentText(state: state)
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(state.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressBar(state: state)
                        DetailLine(state: state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                PhaseIcon(phase: state.phase)
            } compactTrailing: {
                PercentText(state: state)
                    .font(.caption.weight(.semibold))
            } minimal: {
                ProgressRing(state: state)
            }
            .keylineTint(DownloadActivityStyle.accent)
        }
    }
}

enum DownloadActivityStyle {
    /// The app's accent colour.
    static let accent = Color(red: 0.898, green: 0.071, blue: 0.098)
}

private struct LockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PosterView(data: state.poster, width: 46)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(state.status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let subtitle = state.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                ProgressBar(state: state)
                    .padding(.top, 10)
                HStack(alignment: .firstTextBaseline) {
                    DetailLine(state: state)
                    Spacer(minLength: 4)
                    PercentText(state: state)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

private struct PosterView: View {
    let data: Data?
    let width: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "film")
                        .font(.system(size: width * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.14, style: .continuous))
    }
}

private struct ProgressBar: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        ProgressView(value: min(max(state.progress, 0), 1))
            .progressViewStyle(.linear)
            .tint(state.phase == .failed ? .orange : (state.phase == .completed ? .green : DownloadActivityStyle.accent))
    }
}

/// "4,3 MB / 7,38 GB · 281 KB/s", formatted in the iPhone's language, plus how many titles wait.
private struct DetailLine: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        line
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var text: String {
        let format = ByteCountFormatStyle(style: .file)
        var parts: [String] = []
        if let total = state.totalBytes, total > 0, state.phase != .completed {
            parts.append("\(state.bytesWritten.formatted(format)) / \(total.formatted(format))")
        } else {
            parts.append(max(state.bytesWritten, state.totalBytes ?? 0).formatted(format))
        }
        if state.phase == .downloading, let speed = state.bytesPerSecond, speed > 0 {
            parts.append("\(Int64(speed).formatted(format))/s")
        }
        return parts.joined(separator: " · ")
    }

    private var line: Text {
        guard state.queued > 0 else { return Text(text) }
        return Text("\(text)   \(Image(systemName: "square.stack.fill")) \(state.queued)")
    }
}

private struct PercentText: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        Group {
            switch state.phase {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            default:
                Text(min(max(state.progress, 0), 1).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(DownloadActivityStyle.accent)
            }
        }
    }
}

private struct PhaseIcon: View {
    let phase: DownloadActivityAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(DownloadActivityStyle.accent)
        case .waiting: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct ProgressRing: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(state.progress, 0), 1))
                .stroke(state.phase == .completed ? Color.green : DownloadActivityStyle.accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
    }
}
