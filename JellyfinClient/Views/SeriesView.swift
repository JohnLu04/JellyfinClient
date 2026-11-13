import SwiftUI

struct SeriesView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let series: BaseItem

    @State private var seasons: [BaseItem] = []
    @State private var selectedSeasonId: String?
    @State private var episodes: [BaseItem] = []
    @State private var isLoadingEpisodes = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    RemoteImage(url: app.api?.backdropURL(for: series), placeholderSymbol: "tv")
                        .aspectRatio(16 / 9, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(series.name ?? "")
                            .font(.title.bold())
                        HStack(spacing: 8) {
                            if let year = series.productionYear { Text(String(year)) }
                            if let rating = series.officialRating { Text(rating).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary)) }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        if let overview = series.overview {
                            Text(overview)
                                .font(.subheadline)
                                .lineLimit(5)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }

            if seasons.count > 1 {
                Picker("Season", selection: $selectedSeasonId) {
                    ForEach(seasons) { season in
                        Text(season.name ?? String(localized: "Season")).tag(Optional(season.id))
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                if isLoadingEpisodes && episodes.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(episodes) { episode in
                    NavigationLink(value: episode) {
                        EpisodeRow(episode: episode, download: downloads.record(for: episode.id))
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(series.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { if seasons.isEmpty { await loadSeasons() } }
        .task(id: selectedSeasonId) { await loadEpisodes() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task { await loadEpisodes() }
        }
    }

    private func loadSeasons() async {
        guard let api = app.api else { return }
        do {
            seasons = try await api.seasons(seriesId: series.id)
            // Start on the first season that isn't fully watched.
            selectedSeasonId = (seasons.first { $0.userData?.played != true } ?? seasons.first)?.id
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let api = app.api, let seasonId = selectedSeasonId else { return }
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        do {
            episodes = try await api.episodes(seriesId: series.id, seasonId: seasonId)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EpisodeRow: View {
    @Environment(AppModel.self) private var app
    let episode: BaseItem
    let download: DownloadRecord?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: app.api?.backdropURL(for: episode, maxWidth: 400))
                .frame(width: 130, height: 73)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) { if let f = episode.progressFraction { WatchProgressBar(fraction: f) } }
                .overlay(alignment: .topTrailing) { if episode.userData?.played == true { PlayedBadge().font(.caption) } }
            VStack(alignment: .leading, spacing: 3) {
                Text([episode.indexNumber.map { "\($0)." }, episode.name].compactMap { $0 }.joined(separator: " "))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let runtime = episode.runtimeText { Text(runtime) }
                    if let download { DownloadStateIcon(record: download) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let overview = episode.overview {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
