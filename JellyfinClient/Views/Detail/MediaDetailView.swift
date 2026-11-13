import SwiftUI

/// Title page for movies, series and episodes: trailer header, play/download buttons, description,
/// cast, actions (My List, Share, playback options, season download) and tabs (episodes, similar titles).
struct MediaDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @AppStorage(SettingsKeys.downloadMbit) private var defaultDownloadMbit = 4.0

    @State private var item: BaseItem
    @State private var isFavorite: Bool
    @State private var streamingMbit: Double
    /// Audio/subtitle choice for `playableItem`; reset when that changes.
    @State private var selection: TrackSelection?

    // Series
    @State private var seasons: [BaseItem] = []
    @State private var selectedSeasonId: String?
    @State private var episodes: [BaseItem] = []
    @State private var nextEpisode: BaseItem?

    @State private var similar: [BaseItem] = []
    @State private var tab: Tab = .episodes
    @State private var overviewExpanded = false
    @State private var castExpanded = false
    @State private var downloadSheetItem: BaseItem?
    @State private var showOptions = false
    @State private var confirmSeasonDownload = false
    @State private var isStarting = false
    @State private var errorMessage: String?

    private enum Tab: Hashable { case episodes, similar }

    init(item: BaseItem) {
        _item = State(initialValue: item)
        _isFavorite = State(initialValue: item.isFavorite)
        _streamingMbit = State(initialValue: UserDefaults.standard.double(forKey: SettingsKeys.streamingMbit))
        if item.type != "Series", item.primaryMediaSource?.mediaStreams != nil {
            _selection = State(initialValue: .defaults(for: item.primaryMediaSource))
        }
    }

    private var isSeries: Bool { item.type == "Series" }
    /// What "Play" and "Download" act on: the item itself, or a series' next episode.
    private var playableItem: BaseItem? { isSeries ? nextEpisode : item }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TrailerHero(item: item, topInset: geo.safeAreaInsets.top)
                        .frame(height: geo.size.width * 9 / 16 + geo.safeAreaInsets.top)

                    VStack(alignment: .leading, spacing: 14) {
                        header
                        playButton
                        downloadButton
                        overview
                        credits
                        actionRow
                        if isSeries || !similar.isEmpty { tabs }
                    }
                    .padding(.horizontal)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .task(id: selectedSeasonId) { await loadEpisodes() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task { await refresh(); await loadEpisodes() }
        }
        .sheet(item: $downloadSheetItem) { DownloadOptionsSheet(item: $0) }
        .sheet(isPresented: $showOptions) {
            PlaybackOptionsSheet(item: playableItem, selection: $selection, mbit: $streamingMbit,
                                 onPlayFromStart: (playableItem?.resumeTicks ?? 0) > 0 ? { play(fromStart: true) } : nil)
        }
        .confirmationDialog(seasonDownloadTitle, isPresented: $confirmSeasonDownload, titleVisibility: .visible) {
            Button("Original Files") { downloadSeason(mbit: nil) }
            Button("Transcoded · \(Bitrate.label(defaultDownloadMbit))") { downloadSeason(mbit: defaultDownloadMbit) }
        } message: {
            Text("Episodes that are already downloaded are skipped.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.type == "Episode" {
                Text([item.seriesName, item.shortEpisodeLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(item.name ?? "")
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if let year = item.productionYear { Text(String(year)) }
                if let rating = item.officialRating {
                    Text(rating)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                }
                if isSeries {
                    let count = item.childCount ?? seasons.count
                    if count > 0 { Text(count == 1 ? String(localized: "1 Season") : String(localized: "\(count) Seasons")) }
                } else if let runtime = item.runtimeText {
                    Text(runtime)
                }
                if let badge = item.videoQualityBadge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary))
                }
                if item.hasSubtitles {
                    Image(systemName: "captions.bubble")
                        .accessibilityLabel("Subtitles available")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var playButton: some View {
        Button { play(fromStart: false) } label: {
            HStack(spacing: 10) {
                if isStarting {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(playLabel)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(.black)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(playableItem == nil || isStarting)
        .opacity(playableItem == nil ? 0.6 : 1)
    }

    private var playLabel: String {
        guard let target = playableItem else { return String(localized: "Play") }
        let resume = target.resumeTicks > 0
        if isSeries, let label = target.shortEpisodeLabel {
            return resume ? String(localized: "Resume \(label)") : String(localized: "Play \(label)")
        }
        return resume ? String(localized: "Resume from \(Ticks.clockText(target.resumeTicks))") : String(localized: "Play")
    }

    @ViewBuilder
    private var downloadButton: some View {
        if let target = playableItem {
            let record = downloads.record(for: target.id)
            Button {
                switch record?.state {
                case .completed?:
                    if let record, let url = downloads.fileURL(for: record) {
                        PlaybackCoordinator.shared.playLocal(fileURL: url, title: target.name ?? record.name)
                    }
                case .downloading?:
                    break
                default:
                    downloadSheetItem = target
                }
            } label: {
                HStack(spacing: 10) {
                    switch record?.state {
                    case .downloading?:
                        ProgressView(value: record?.progress ?? 0)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text("Downloading · \(Int((record?.progress ?? 0) * 100)) %")
                    case .completed?:
                        Image(systemName: "checkmark.circle.fill")
                        Text("Downloaded · Play Offline")
                    case .failed?:
                        Image(systemName: "exclamationmark.arrow.circlepath")
                        Text("Download Failed · Retry")
                    case nil:
                        Image(systemName: "arrow.down.to.line")
                        Text(isSeries ? String(localized: "Download \(target.shortEpisodeLabel ?? "")") : String(localized: "Download"))
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(.primary)
                .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
            .contextMenu {
                if record != nil {
                    Button("Delete Download", systemImage: "trash", role: .destructive) { downloads.delete(id: target.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let text = item.overview, !text.isEmpty {
            Text(text)
                .font(.subheadline)
                .lineLimit(overviewExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { withAnimation { overviewExpanded.toggle() } }
        }
    }

    @ViewBuilder
    private var credits: some View {
        let cast = item.castNames
        let creators = item.creatorNames
        if !cast.isEmpty || !creators.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !cast.isEmpty {
                    let shown = castExpanded ? cast : Array(cast.prefix(3))
                    (Text("Cast: ") + Text(shown.joined(separator: ", "))
                        + Text(cast.count > 3 && !castExpanded ? String(localized: " … more") : "").bold())
                        .onTapGesture { withAnimation { castExpanded.toggle() } }
                }
                if !creators.isEmpty {
                    Text(item.people?.contains { $0.type == "Director" } == true ? "Director: " : "Created by: ")
                        + Text(creators.prefix(3).joined(separator: ", "))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(alignment: .top, spacing: 0) {
            actionButton(isFavorite ? "checkmark" : "plus", "My List") { toggleFavorite() }

            if let url = item.shareURL {
                ShareLink(item: url, subject: Text(item.name ?? ""), message: Text(item.name ?? "")) {
                    actionLabel("paperplane", "Share")
                }
                .buttonStyle(.plain)
            } else {
                actionLabel("paperplane", "Share").opacity(0.35)
            }

            actionButton("slider.horizontal.3", "Audio & Quality") { showOptions = true }
                .disabled(playableItem == nil)

            if isSeries, let season = selectedSeason {
                actionButton("arrow.down.to.line.compact",
                             LocalizedStringKey("Download \(season.name ?? String(localized: "Season"))")) {
                    confirmSeasonDownload = true
                }
                .disabled(episodes.isEmpty)
            }
        }
        .padding(.vertical, 6)
    }

    private func actionButton(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(symbol, title) }
            .buttonStyle(.plain)
    }

    private func actionLabel(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(height: 28)
            Text(title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Tabs

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 28) {
                if isSeries { tabButton("Episodes", .episodes) }
                if !similar.isEmpty { tabButton("More Like This", .similar) }
            }
            .padding(.top, 4)

            switch currentTab {
            case .episodes: episodeList
            case .similar: similarGrid
            }
        }
    }

    private var currentTab: Tab { isSeries ? tab : .similar }

    private func tabButton(_ title: LocalizedStringKey, _ value: Tab) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { tab = value } } label: {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle()
                    .fill(currentTab == value ? Color.accentColor : .clear)
                    .frame(height: 4)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(currentTab == value ? .primary : .secondary)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 18) {
            if seasons.count > 1 {
                Menu {
                    Picker("Season", selection: $selectedSeasonId) {
                        ForEach(seasons) { season in
                            Text(season.name ?? String(localized: "Season")).tag(Optional(season.id))
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(selectedSeason?.name ?? String(localized: "Season"))
                        Image(systemName: "chevron.down").font(.footnote.weight(.bold))
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
            } else if let season = seasons.first {
                Text(season.name ?? "").font(.headline)
            }

            if episodes.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(episodes) { episode in
                EpisodeCell(episode: episode,
                            record: downloads.record(for: episode.id),
                            onPlay: { playEpisode(episode) },
                            onDownload: { episodeDownloadTapped(episode) })
            }
        }
    }

    private var similarGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
            ForEach(similar) { other in
                NavigationLink(value: other) { PosterCard(item: other) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var selectedSeason: BaseItem? { seasons.first { $0.id == selectedSeasonId } }

    private var seasonDownloadTitle: String {
        String(localized: "Download all \(episodes.count) episodes of \(selectedSeason?.name ?? String(localized: "this season"))?")
    }

    // MARK: - Behaviour

    private func refresh() async {
        guard let api = app.api else { return }
        if let fresh = try? await api.item(id: item.id) {
            item = fresh
            isFavorite = fresh.isFavorite
            if selection == nil, !isSeries, fresh.primaryMediaSource?.mediaStreams != nil {
                selection = .defaults(for: fresh.primaryMediaSource)
            }
        }
        if isSeries {
            async let seasonsRequest = api.seasons(seriesId: item.id)
            async let nextRequest = api.episodeToPlay(seriesId: item.id)
            let loadedSeasons = (try? await seasonsRequest) ?? []
            let next = try? await nextRequest
            seasons = loadedSeasons
            if nextEpisode?.id != next?.id { selection = next.map { .defaults(for: $0.primaryMediaSource) } }
            nextEpisode = next
            if selectedSeasonId == nil {
                selectedSeasonId = loadedSeasons.first { $0.id == next?.seasonId }?.id
                    ?? loadedSeasons.first { $0.userData?.played != true }?.id
                    ?? loadedSeasons.first?.id
            }
        }
        if similar.isEmpty {
            similar = (try? await api.similar(itemId: isSeries || item.type == "Movie" ? item.id : (item.seriesId ?? item.id))) ?? []
        }
    }

    private func loadEpisodes() async {
        guard isSeries, let api = app.api, let seasonId = selectedSeasonId else { return }
        if let loaded = try? await api.episodes(seriesId: item.id, seasonId: seasonId) {
            episodes = loaded
        }
    }

    private func play(fromStart: Bool) {
        guard let api = app.api, let target = playableItem else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                try await PlaybackCoordinator.shared.play(
                    item: target, api: api, maxMbit: streamingMbit,
                    startTicks: fromStart ? 0 : target.resumeTicks,
                    selection: selection ?? .defaults(for: target.primaryMediaSource))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func playEpisode(_ episode: BaseItem) {
        guard let api = app.api else { return }
        Task {
            do {
                try await PlaybackCoordinator.shared.play(
                    item: episode, api: api, maxMbit: streamingMbit, startTicks: episode.resumeTicks,
                    selection: .defaults(for: episode.primaryMediaSource))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func episodeDownloadTapped(_ episode: BaseItem) {
        let record = downloads.record(for: episode.id)
        if record?.state == .completed, let record, let url = downloads.fileURL(for: record) {
            PlaybackCoordinator.shared.playLocal(fileURL: url, title: episode.name ?? record.name)
        } else if record?.state != .downloading {
            downloadSheetItem = episode
        }
    }

    private func downloadSeason(mbit: Double?) {
        guard let api = app.api else { return }
        for episode in episodes {
            switch downloads.record(for: episode.id)?.state {
            case .completed?, .downloading?: continue
            default: downloads.start(item: episode, api: api, mbit: mbit)
            }
        }
    }

    private func toggleFavorite() {
        guard let api = app.api else { return }
        let newValue = !isFavorite
        isFavorite = newValue
        Task {
            do {
                try await api.setFavorite(itemId: item.id, newValue)
            } catch {
                isFavorite = !newValue
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Episode row

struct EpisodeCell: View {
    @Environment(AppModel.self) private var app
    let episode: BaseItem
    let record: DownloadRecord?
    let onPlay: () -> Void
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onPlay) {
                    ZStack {
                        RemoteImage(url: app.api?.backdropURL(for: episode, maxWidth: 400), placeholderSymbol: "tv")
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.45), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                    }
                    .frame(width: 136, height: 77)
                    .overlay(alignment: .bottom) { if let f = episode.progressFraction { WatchProgressBar(fraction: f) } }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(episode.name ?? "")")

                NavigationLink(value: episode) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text([episode.indexNumber.map { "\($0)." }, episode.name].compactMap { $0 }.joined(separator: " "))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if let runtime = episode.runtimeText {
                            Text(runtime).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onDownload) { downloadIcon }
                    .buttonStyle(.plain)
                    .frame(width: 36, height: 36)
            }
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var downloadIcon: some View {
        switch record?.state {
        case .downloading?:
            ProgressView(value: record?.progress ?? 0)
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .completed?:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint)
        case .failed?:
            Image(systemName: "exclamationmark.circle").font(.title3).foregroundStyle(.red)
        case nil:
            Image(systemName: "arrow.down.to.line").font(.title3)
        }
    }
}

// MARK: - Playback options

struct PlaybackOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: BaseItem?
    @Binding var selection: TrackSelection?
    @Binding var mbit: Double
    let onPlayFromStart: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                if let onPlayFromStart {
                    Section {
                        Button("Play from Beginning", systemImage: "arrow.counterclockwise") {
                            dismiss()
                            onPlayFromStart()
                        }
                    }
                }

                if let source = item?.primaryMediaSource, !source.audioStreams.isEmpty || !source.subtitleStreams.isEmpty {
                    let current = selection ?? .defaults(for: source)
                    Section {
                        if !source.audioStreams.isEmpty {
                            Picker("Audio", selection: Binding(
                                get: { current.audioIndex },
                                set: { selection = TrackSelection(audioIndex: $0, subtitleIndex: current.subtitleIndex) }
                            )) {
                                ForEach(source.audioStreams) { Text($0.label).tag(Optional($0.index)) }
                            }
                        }
                        Picker("Subtitles", selection: Binding(
                            get: { current.subtitleIndex },
                            set: { selection = TrackSelection(audioIndex: current.audioIndex, subtitleIndex: $0) }
                        )) {
                            Text("Off").tag(Int?.none)
                            ForEach(source.subtitleStreams) { Text($0.label).tag(Optional($0.index)) }
                        }
                    } header: {
                        Text("Audio & Subtitles")
                    } footer: {
                        if let name = item?.type == "Episode" ? item?.shortEpisodeLabel : nil {
                            Text("Applies to \(name). You can also switch tracks in the player.")
                        }
                    }
                }

                Section {
                    StreamingQualityControl(mbit: $mbit)
                } header: {
                    Text("Streaming Quality · \(Bitrate.label(mbit))")
                }
            }
            .navigationTitle("Playback Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
