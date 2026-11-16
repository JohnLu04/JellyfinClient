import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false
    @State private var folderToDelete: DownloadFolder?

    var body: some View {
        NavigationStack {
            List {
                // Movies as they are; episodes in a folder per series (and season).
                ForEach(downloads.records.listEntries) { entry in
                    switch entry {
                    case .record(let record):
                        DownloadItemRow(record: record)
                    case .series(let folder):
                        DownloadFolderLink(folder: folder, route: .series(folder.key), toDelete: $folderToDelete)
                    }
                }
            }
            .listStyle(.plain)
            .deleteFolderDialog($folderToDelete)
            .overlay {
                if downloads.records.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("Movies and episodes you download appear here and can be watched offline."))
                }
            }
            .navigationTitle("Downloads")
            .navigationDestination(for: DownloadRoute.self) { route in
                switch route {
                case .series(let key): DownloadSeriesView(seriesKey: key)
                case .season(let series, let season): DownloadSeasonView(seriesKey: series, seasonKey: season)
                }
            }
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

// MARK: - Folders

/// Where a folder in the download list leads.
enum DownloadRoute: Hashable {
    case series(String)
    case season(series: String, season: String)
}

/// The episodes of one series or one season.
struct DownloadFolder: Identifiable {
    let key: String
    let title: String
    let records: [DownloadRecord]
    var id: String { key }
}

enum DownloadListEntry: Identifiable {
    case record(DownloadRecord)
    case series(DownloadFolder)

    var id: String {
        switch self {
        case .record(let record): "item:" + record.id
        case .series(let folder): "series:" + folder.key
        }
    }
}

extension [DownloadRecord] {
    /// Movies, and one folder per series – in the order of each one's newest download.
    var listEntries: [DownloadListEntry] {
        var entries: [DownloadListEntry] = []
        var seen: Set<String> = []
        for record in self {
            guard let key = record.seriesKey else {
                entries.append(.record(record))
                continue
            }
            if seen.insert(key).inserted, let folder = seriesFolder(key) { entries.append(.series(folder)) }
        }
        return entries
    }

    /// All downloaded episodes of a series, by season and episode.
    func seriesFolder(_ key: String) -> DownloadFolder? {
        let episodes = filter { $0.seriesKey == key }.sorted { a, b in
            let (sa, sb) = (Self.seasonOrder(a), Self.seasonOrder(b))
            if sa != sb { return sa < sb }
            let (ea, eb) = (a.episodeInfo?.episode ?? .max, b.episodeInfo?.episode ?? .max)
            if ea != eb { return ea < eb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        guard !episodes.isEmpty else { return nil }
        return DownloadFolder(key: key, title: key, records: episodes)
    }

    /// The seasons of a series that have downloads, in order.
    func seasonFolders(ofSeries key: String) -> [DownloadFolder] {
        var order: [String] = []
        var groups: [String: [DownloadRecord]] = [:]
        for episode in seriesFolder(key)?.records ?? [] {
            let season = episode.seasonKey ?? "-"
            if groups[season] == nil { order.append(season) }
            groups[season, default: []].append(episode)
        }
        return order.compactMap { season in
            groups[season].map { DownloadFolder(key: season, title: Self.seasonTitle($0[0]), records: $0) }
        }
    }

    /// Specials (season 0) and episodes without a season come after the numbered seasons.
    private static func seasonOrder(_ record: DownloadRecord) -> Int {
        guard let season = record.episodeInfo?.season, season > 0 else { return .max - (record.episodeInfo?.season == 0 ? 1 : 0) }
        return season
    }

    static func seasonTitle(_ record: DownloadRecord) -> String {
        switch record.episodeInfo?.season {
        case let season? where season > 0: String(localized: "Season \(season)")
        case 0?: record.seasonName ?? String(localized: "Specials")
        default: record.seasonName ?? String(localized: "Episodes")
        }
    }
}

/// A series' folder: its seasons, or straight its episodes when there's only one season.
struct DownloadSeriesView: View {
    @Environment(DownloadManager.self) private var downloads
    let seriesKey: String
    @State private var seasonToDelete: DownloadFolder?

    var body: some View {
        let seasons = downloads.records.seasonFolders(ofSeries: seriesKey)
        List {
            if seasons.count == 1, let season = seasons.first {
                Section(season.title) {
                    ForEach(season.records) { DownloadItemRow(record: $0, inFolder: true) }
                }
            } else {
                ForEach(seasons) { season in
                    DownloadFolderLink(folder: season, route: .season(series: seriesKey, season: season.key), toDelete: $seasonToDelete)
                }
            }
        }
        .listStyle(.plain)
        .deleteFolderDialog($seasonToDelete)
        .overlay {
            if seasons.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle(seriesKey)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A season's folder: its downloaded episodes.
struct DownloadSeasonView: View {
    @Environment(DownloadManager.self) private var downloads
    let seriesKey: String
    let seasonKey: String

    var body: some View {
        let season = downloads.records.seasonFolders(ofSeries: seriesKey).first { $0.key == seasonKey }
        List {
            ForEach(season?.records ?? []) { DownloadItemRow(record: $0, inFolder: true) }
        }
        .listStyle(.plain)
        .overlay {
            if season == nil {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle(season?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A series or season folder in the list; swiping offers to delete all its episodes.
struct DownloadFolderLink: View {
    let folder: DownloadFolder
    let route: DownloadRoute
    @Binding var toDelete: DownloadFolder?

    var body: some View {
        NavigationLink(value: route) {
            DownloadFolderRow(folder: folder, isSeries: { if case .series = route { true } else { false } }())
        }
        .swipeActions {
            Button(role: .destructive) { toDelete = folder } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Asks before deleting a whole folder. On the list, not the row: a row's dialog doesn't show after a swipe action.
private struct DeleteFolderDialog: ViewModifier {
    @Environment(DownloadManager.self) private var downloads
    @Binding var folder: DownloadFolder?

    func body(content: Content) -> some View {
        let count = folder?.records.count ?? 0
        content.confirmationDialog(count == 1 ? String(localized: "Delete this episode?") : String(localized: "Delete all \(count) episodes?"),
                                   isPresented: Binding(get: { folder != nil }, set: { if !$0 { folder = nil } }),
                                   titleVisibility: .visible, presenting: folder) { folder in
            Button(folder.records.count == 1 ? String(localized: "Delete") : String(localized: "Delete All"), role: .destructive) {
                for record in folder.records { downloads.delete(id: record.id) }
            }
        } message: { folder in
            Text("\(folder.title) – the downloaded files are removed from this iPhone.")
        }
    }
}

extension View {
    func deleteFolderDialog(_ folder: Binding<DownloadFolder?>) -> some View {
        modifier(DeleteFolderDialog(folder: folder))
    }
}

struct DownloadFolderRow: View {
    @Environment(DownloadManager.self) private var downloads
    let folder: DownloadFolder
    let isSeries: Bool

    var body: some View {
        HStack(spacing: 12) {
            poster
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                        .padding(4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(3)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.title).font(.headline).lineLimit(2)
                Text(contentsText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let loading = folder.records.first(where: { $0.state == .downloading }) {
                    ProgressView(value: loading.displayProgress)
                    Text(loadingText(loading)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                } else if let status = statusText {
                    Text(status).font(.caption)
                        .foregroundStyle(folder.records.contains { $0.state == .failed } ? .red : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// "2 seasons · 5 episodes · 3.2 GB"
    private var contentsText: String {
        var parts: [String] = []
        if isSeries {
            let seasons = Set(folder.records.map { $0.seasonKey ?? "-" }).count
            if seasons > 1 { parts.append(String(localized: "\(seasons) Seasons")) }
        }
        let count = folder.records.count
        parts.append(count == 1 ? String(localized: "1 episode") : String(localized: "\(count) episodes"))
        let size = folder.records.filter { $0.state == .completed }.reduce(Int64(0)) { $0 + $1.bytesWritten }
        if size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    /// "Loading S1 · E3 · 45 % · 2 waiting"
    private func loadingText(_ record: DownloadRecord) -> String {
        var parts = [String(localized: "Loading \(Self.episodeLabel(record)) · \(Int(record.displayProgress * 100)) %")]
        let waiting = folder.records.filter { $0.state == .queued }.count
        if waiting > 0 { parts.append(String(localized: "\(waiting) waiting")) }
        return parts.joined(separator: " · ")
    }

    /// "2 waiting · 1 paused · 1 failed", or nil when everything is downloaded.
    private var statusText: String? {
        var parts: [String] = []
        let waiting = folder.records.filter { $0.state == .queued }.count
        let paused = folder.records.filter { $0.state == .paused }.count
        let failed = folder.records.filter { $0.state == .failed }.count
        if waiting > 0 { parts.append(String(localized: "\(waiting) waiting")) }
        if paused > 0 { parts.append(String(localized: "\(paused) paused")) }
        if failed > 0 { parts.append(String(localized: "\(failed) failed")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func episodeLabel(_ record: DownloadRecord) -> String {
        switch (record.episodeInfo?.season, record.episodeInfo?.episode) {
        case let (s?, e?): "S\(s) · E\(e)"
        case let (nil, e?): "E\(e)"
        default: record.name
        }
    }

    @ViewBuilder
    private var poster: some View {
        let _ = downloads.posterRevision
        // The series poster for a series, the season's (saved with its episodes) for a season.
        let seriesPoster = isSeries ? folder.records.lazy.compactMap(\.seriesId).first.flatMap { downloads.seriesPosterURL(seriesId: $0) } : nil
        let url = seriesPoster ?? folder.records.lazy.compactMap { downloads.posterURL(for: $0) }.first
        if let url, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            RemoteImage(url: nil)
        }
    }
}

/// One download: tap plays, pauses, resumes or retries it; swipe for more.
struct DownloadItemRow: View {
    @Environment(DownloadManager.self) private var downloads
    let record: DownloadRecord
    var inFolder = false

    var body: some View {
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
            DownloadRow(record: record, inFolder: inFolder)
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

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    let record: DownloadRecord
    /// In a series or season folder: "Episode 3" instead of the series' name.
    var inFolder = false

    var body: some View {
        HStack(spacing: 12) {
            poster
                .frame(width: 60, height: 90)
                .overlay(alignment: .bottom) { watchProgress }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                if let caption = inFolder ? record.episodeInfo?.episode.map({ String(localized: "Episode \($0)") }) : record.subtitle {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
