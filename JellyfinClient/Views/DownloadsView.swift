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
                            if let url = downloads.fileURL(for: record) {
                                PlaybackCoordinator.shared.playLocal(fileURL: url, title: record.name)
                            }
                        case .failed:
                            downloads.retry(id: record.id)
                        case .queued, .downloading:
                            break
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                if let subtitle = record.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(record.name).font(.headline).lineLimit(2)
                switch record.state {
                case .queued:
                    ProgressView(value: record.progress)
                        .tint(.secondary)
                    Text(record.errorMessage ?? String(localized: "Waiting…"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                case .downloading:
                    ProgressView(value: record.progress)
                    Text(record.errorMessage ?? progressText)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                case .completed:
                    Text("\(record.qualityLabel) · \(ByteCountFormatter.string(fromByteCount: record.bytesWritten, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
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
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        case .completed: Image(systemName: "play.circle.fill").foregroundStyle(.tint)
        case .failed: Image(systemName: "arrow.clockwise.circle").foregroundStyle(.red)
        }
    }
}
