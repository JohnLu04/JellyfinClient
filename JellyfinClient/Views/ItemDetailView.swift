import SwiftUI

struct ItemDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads

    @State private var item: BaseItem
    /// Per-title streaming limit in Mbit/s (0 = Original), prefilled from Settings.
    @State private var streamingMbit: Double
    /// Audio/subtitle choice; filled from the server's defaults once streams are known.
    @State private var selection: TrackSelection?
    @AppStorage(SettingsKeys.videoPlayer) private var videoPlayer = PlayerKind.defaultKind.rawValue
    @State private var isStarting = false
    @State private var showDownloadOptions = false
    @State private var errorMessage: String?

    init(item: BaseItem) {
        _item = State(initialValue: item)
        _streamingMbit = State(initialValue: UserDefaults.standard.double(forKey: SettingsKeys.streamingMbit))
        if item.primaryMediaSource?.mediaStreams != nil {
            _selection = State(initialValue: .defaults(for: item.primaryMediaSource))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RemoteImage(url: app.api?.backdropURL(for: item))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .bottom) { if let f = item.progressFraction { WatchProgressBar(fraction: f) } }

                VStack(alignment: .leading, spacing: 16) {
                    header
                    playButtons
                    tracksBox
                    qualityBox
                    downloadBox
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview).font(.body)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(item.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(item: item)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let seriesName = item.seriesName {
                Text(seriesName).font(.headline).foregroundStyle(.secondary)
            }
            Text(item.name ?? "").font(.title.bold())
            HStack(spacing: 10) {
                if let label = item.episodeLabel { Text(label) }
                if let year = item.productionYear { Text(String(year)) }
                if let runtime = item.runtimeText { Text(runtime) }
                if let rating = item.officialRating {
                    Text(rating)
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary))
                }
                if let score = item.communityRating {
                    Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var playButtons: some View {
        VStack(spacing: 10) {
            if item.resumeTicks > 0 {
                Button { play(fromTicks: item.resumeTicks) } label: {
                    Label("Resume from \(Ticks.clockText(item.resumeTicks))", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button { play(fromTicks: 0) } label: {
                    Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button { play(fromTicks: 0) } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .disabled(isStarting)
        .overlay { if isStarting { ProgressView() } }

        Text("Player: \((PlayerKind(rawValue: videoPlayer) ?? .defaultKind).title) · change in Settings")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var tracksBox: some View {
        if let source = item.primaryMediaSource, !source.audioStreams.isEmpty || !source.subtitleStreams.isEmpty {
            let current = selection ?? .defaults(for: source)
            GroupBox {
                VStack(spacing: 6) {
                    if !source.audioStreams.isEmpty {
                        LabeledContent("Audio") {
                            Picker("Audio", selection: Binding(
                                get: { current.audioIndex },
                                set: { selection = TrackSelection(audioIndex: $0, subtitleIndex: current.subtitleIndex) }
                            )) {
                                ForEach(source.audioStreams) { stream in
                                    Text(stream.label).tag(Optional(stream.index))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    LabeledContent("Subtitles") {
                        Picker("Subtitles", selection: Binding(
                            get: { current.subtitleIndex },
                            set: { selection = TrackSelection(audioIndex: current.audioIndex, subtitleIndex: $0) }
                        )) {
                            Text("Off").tag(Int?.none)
                            ForEach(source.subtitleStreams) { stream in
                                Text(stream.label).tag(Optional(stream.index))
                            }
                        }
                        .labelsHidden()
                    }
                }
            } label: {
                Label("Audio & Subtitles", systemImage: "captions.bubble")
            }
        }
    }

    private var qualityBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                StreamingQualityControl(mbit: $streamingMbit)
            }
        } label: {
            HStack {
                Label("Streaming Quality", systemImage: "dial.medium")
                Spacer()
                Text(Bitrate.label(streamingMbit)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var downloadBox: some View {
        GroupBox {
            if let record = downloads.record(for: item.id) {
                switch record.state {
                case .downloading:
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: record.progress)
                        HStack {
                            Text("Downloading \(record.qualityLabel) · \(Int(record.progress * 100)) %")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel", role: .destructive) { downloads.delete(id: item.id) }
                                .font(.caption)
                        }
                    }
                case .completed:
                    HStack {
                        Label("Downloaded · \(record.qualityLabel)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Play Offline") { playOffline(record) }
                            .buttonStyle(.bordered)
                    }
                case .failed:
                    VStack(alignment: .leading, spacing: 8) {
                        Label(record.errorMessage ?? String(localized: "Download failed"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Button("Try Again") { showDownloadOptions = true }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                Button { showDownloadOptions = true } label: {
                    Label("Download…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } label: {
            Label("Offline", systemImage: "arrow.down.to.line")
        }
    }

    // MARK: - Actions

    private func refresh() async {
        guard let api = app.api else { return }
        if let fresh = try? await api.item(id: item.id) {
            item = fresh
            if selection == nil, fresh.primaryMediaSource?.mediaStreams != nil {
                selection = .defaults(for: fresh.primaryMediaSource)
            }
        }
    }

    private func play(fromTicks ticks: Int64) {
        guard let api = app.api else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                try await PlaybackCoordinator.shared.play(item: item, api: api, maxMbit: streamingMbit, startTicks: ticks,
                                                          selection: selection ?? .defaults(for: item.primaryMediaSource))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func playOffline(_ record: DownloadRecord) {
        guard let url = downloads.fileURL(for: record) else { return }
        PlaybackCoordinator.shared.playLocal(fileURL: url, title: item.name ?? record.name)
    }
}

// MARK: - Download options

struct DownloadOptionsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    let item: BaseItem

    private enum Mode: Hashable { case original, transcoded }
    @State private var mode: Mode
    @State private var mbit: Double

    init(item: BaseItem) {
        self.item = item
        let stored = UserDefaults.standard.object(forKey: SettingsKeys.downloadMbit) as? Double
        _mbit = State(initialValue: Bitrate.snap(stored ?? 4))
        // mpv plays any container offline, so the original file is the better default there.
        let originalPlays = PlayerKind.current == .mpv || Self.isNativeContainer(item)
        _mode = State(initialValue: originalPlays ? .original : .transcoded)
    }

    private static func isNativeContainer(_ item: BaseItem) -> Bool {
        guard let container = item.primaryMediaSource?.container?.lowercased() else { return false }
        return container.split(separator: ",").contains { ["mp4", "m4v", "mov"].contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Version", selection: $mode) {
                        Text("Original").tag(Mode.original)
                        Text("Transcoded").tag(Mode.transcoded)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    switch mode {
                    case .original:
                        Text("Downloads the unchanged file. Requires the “Allow media downloading” permission on the server.")
                    case .transcoded:
                        Text("The server converts the video to H.264/AAC (MP4) at the chosen bitrate. Requires the transcoding permission. The download takes about as long as the server needs to transcode.")
                    }
                }

                if mode == .transcoded {
                    Section("Bitrate") {
                        BitrateStepper(mbit: $mbit)
                    }
                }

                Section {
                    if let size = estimatedSize {
                        LabeledContent(mode == .original ? "File size" : "Estimated size",
                                       value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if mode == .original, let container = item.primaryMediaSource?.container {
                        LabeledContent("Format", value: container.uppercased())
                        if !Self.isNativeContainer(item) && PlayerKind.current == .native {
                            Label("The Apple player can't play this format offline. Choose “Transcoded” or switch to mpv in Settings.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        guard let api = app.api else { return }
                        downloads.start(item: item, api: api, mbit: mode == .transcoded ? mbit : nil)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var estimatedSize: Int64? {
        switch mode {
        case .original: return item.primaryMediaSource?.size
        case .transcoded: return Bitrate.estimatedBytes(mbit: mbit, runTimeTicks: item.runTimeTicks)
        }
    }
}
