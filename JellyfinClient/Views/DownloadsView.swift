import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(downloads.records) { record in
                    Button {
                        switch record.state {
                        case .completed:
                            downloads.play(record)
                        case .failed:
                            downloads.retry(id: record.id)
                        case .queued, .downloading:
                            downloads.pause(id: record.id)
                        case .paused:
                            downloads.resume(id: record.id)
                        }
                    } label: {
                        DownloadRow(record: record)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { downloads.delete(id: record.id) } label: {
                            Label(record.isActive ? "Cancel" : "Delete", systemImage: "trash")
                        }
                        if record.state == .failed {
                            Button { downloads.retry(id: record.id) } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .tint(.accentColor)
                        }
                        if record.isActive {
                            Button { downloads.pause(id: record.id) } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            .tint(.orange)
                        } else if record.state == .paused {
                            Button { downloads.resume(id: record.id) } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                            .tint(.accentColor)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if downloads.records.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("Movies and episodes you download appear here and can be watched offline."))
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Download Log", systemImage: "doc.text.magnifyingglass") { showLog = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if downloads.hasActiveDownloads {
                        Button("Pause All", systemImage: "pause.circle") { downloads.pauseAll() }
                    } else if downloads.hasPausedDownloads {
                        Button("Resume All", systemImage: "play.circle") { downloads.resumeAll() }
                    }
                }
            }
            .sheet(isPresented: $showLog) { DownloadLogView() }
        }
    }
}

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 12) {
            poster
                .frame(width: 60, height: 90)
                .overlay(alignment: .bottom) { watchProgress }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                if let subtitle = record.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(record.name).font(.headline).lineLimit(2)
                switch record.state {
                case .queued:
                    ProgressView(value: record.displayProgress)
                        .tint(.secondary)
                    Text(record.errorMessage ?? String(localized: "Waiting…"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                case .downloading:
                    ProgressView(value: record.displayProgress)
                    if let title = extraTitleText {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(record.errorMessage ?? extraProgressText ?? record.extrasProgress.map {
                        String(localized: "Audio tracks & subtitles · \($0.done + 1) of \($0.total)")
                    } ?? progressText)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                case .paused:
                    ProgressView(value: record.displayProgress)
                        .tint(.secondary)
                    if let title = extraTitleText {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("Paused · \(Int(record.displayProgress * 100)) % · Tap to resume")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                case .completed:
                    Text("\(record.qualityLabel) · \(ByteCountFormatter.string(fromByteCount: record.bytesWritten, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let extras = extrasSummary {
                        Text(extras).font(.caption2).foregroundStyle(.secondary)
                    }
                case .failed:
                    Text(record.errorMessage ?? String(localized: "Failed"))
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            DownloadStateIcon(record: record).font(.title3)
        }
        .contentShape(Rectangle())
    }

    /// "+2 audio tracks · 3 subtitles"
    private var extrasSummary: String? {
        let done = record.finishedExtras
        let audio = done.filter { $0.kind == .audio }.count
        let subs = done.filter { $0.kind == .subtitle }.count
        var parts: [String] = []
        if audio > 0 { parts.append(String(localized: "+\(audio) audio tracks")) }
        if subs > 0 { parts.append(String(localized: "\(subs) subtitles")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "4 Mbit/s · 1.2 GB of 2.3 GB · 8.4 MB/s"
    private var progressText: String {
        var parts = [record.qualityLabel]
        let written = ByteCountFormatter.string(fromByteCount: record.bytesWritten, countStyle: .file)
        if let expected = record.expectedBytes, expected > 0 {
            let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            parts.append(String(localized: "\(written) of \(total)"))
        } else {
            parts.append(written)
        }
        if let speed = downloads.speeds[record.id], speed > 0 {
            parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
        }
        return parts.joined(separator: " · ")
    }

    /// "Audio track 1 of 2 · German" or "Subtitle · English" while an extra file loads after the video.
    private var extraTitleText: String? {
        guard let phase = record.extraPhase else { return nil }
        var parts: [String]
        switch phase.kind {
        case .audio:
            parts = [phase.total > 1 ? String(localized: "Audio track \(phase.number) of \(phase.total)") : String(localized: "Audio track")]
        case .subtitle:
            parts = [phase.total > 1 ? String(localized: "Subtitle \(phase.number) of \(phase.total)") : String(localized: "Subtitle")]
        }
        // "Deutsch - AAC - Stereo" → "Deutsch"
        if let name = phase.extra.title.components(separatedBy: " - ").first, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    /// "1.2 MB of 5.6 MB · 300 KB/s" for the audio track or subtitle that's loading.
    private var extraProgressText: String? {
        guard record.extraPhase != nil else { return nil }
        var parts: [String] = []
        let written = ByteCountFormatter.string(fromByteCount: record.extraBytesWritten ?? 0, countStyle: .file)
        if let expected = record.extraExpectedBytes, expected > 0 {
            let total = ByteCountFormatter.string(fromByteCount: max(expected, record.extraBytesWritten ?? 0), countStyle: .file)
            parts.append(String(localized: "\(written) of \(total)"))
        } else {
            parts.append(written)
        }
        if let speed = downloads.speeds[record.id], speed > 0 {
            parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
        }
        return parts.joined(separator: " · ")
    }

    /// How far it was watched (offline or streamed), like the progress bar on posters elsewhere.
    @ViewBuilder
    private var watchProgress: some View {
        if record.state == .completed, let seconds = record.resumeSeconds, let ticks = record.runTimeTicks, ticks > 0 {
            let fraction = min(1, seconds / Ticks.seconds(ticks))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.55))
                    Rectangle().fill(Color.accentColor).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let url = downloads.posterURL(for: record), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            RemoteImage(url: nil)
        }
    }
}

struct DownloadStateIcon: View {
    let record: DownloadRecord

    var body: some View {
        switch record.state {
        // Running or waiting: a tap pauses. Paused: a tap continues the download.
        case .queued: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .downloading: Image(systemName: "pause.circle.fill").foregroundStyle(.tint)
        case .paused: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
        case .completed: Image(systemName: "play.circle.fill").foregroundStyle(.tint)
        case .failed: Image(systemName: "arrow.clockwise.circle").foregroundStyle(.red)
        }
    }
}
