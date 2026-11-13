import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        NavigationStack {
            List {
                ForEach(downloads.records) { record in
                    Button {
                        if record.state == .completed, let url = downloads.fileURL(for: record) {
                            PlaybackCoordinator.shared.playLocal(fileURL: url, title: record.name)
                        }
                    } label: {
                        DownloadRow(record: record)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { downloads.delete(id: record.id) } label: {
                            Label(record.state == .downloading ? "Cancel" : "Delete", systemImage: "trash")
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
                case .downloading:
                    ProgressView(value: record.progress)
                    Text("\(record.qualityLabel) · \(ByteCountFormatter.string(fromByteCount: record.bytesWritten, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
        case .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        case .completed: Image(systemName: "play.circle.fill").foregroundStyle(.tint)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        }
    }
}
