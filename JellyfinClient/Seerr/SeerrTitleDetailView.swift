import SwiftUI

/// Full-screen page for a Seerr title (as in the Servarr app): backdrop, ratings, streaming, seasons with episodes,
/// and a request with season selection, Radarr/Sonarr server and quality profile.
struct SeerrTitleDetailView: View {
    @Environment(SeerrStore.self) private var seerr
    let item: DiscoverItem
    var onRequested: () -> Void = {}

    @State private var details: SeerrTitleDetails?
    @State private var ratings: SeerrRatings?
    @State private var servers: [SeerrArrServer] = []
    @State private var serverID: Int?
    @State private var profileID: Int?
    @State private var selectedSeasons: Set<Int> = []
    @State private var shownSeason: Int?
    @State private var episodes: [Int: [SeerrEpisode]] = [:]
    @State private var isRequesting = false
    @State private var didRequest = false
    @State private var errorMessage: String?

    private var service: SeerrClient? { seerr.client }
    private var state: SeerrState? { didRequest ? .pendingApproval : (details?.state ?? item.state) }
    private var isTV: Bool { item.mediaType == .tv }
    private var server: SeerrArrServer? { servers.first { $0.id == serverID } }
    /// Seasons that can still be requested (not already on the server or on their way).
    private var requestableSeasons: [SeerrSeason] {
        (details?.seasons ?? []).filter { $0.number > 0 && $0.state != .available && $0.state != .processing }
    }
    private var canRequest: Bool {
        guard !didRequest else { return false }
        if isTV { return !requestableSeasons.isEmpty }
        return state == nil || state == .declined || state == .failed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                VStack(alignment: .leading, spacing: 22) {
                    if let ratings, !ratings.isEmpty || details?.tmdbScore != nil {
                        RatingsRow(ratings: ratings, tmdbScore: details?.tmdbScore)
                    }
                    if !(state == .available) {
                        StreamingAvailabilityView(type: item.mediaType, tmdbID: item.tmdbID)
                            .card(padding: 14)
                    }
                    overview
                    if isTV, let details, !details.seasons.isEmpty { seasonsSection(details.seasons) }
                    requestSection
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
        .themedBackground()
        .ignoresSafeArea(edges: .top)
        .navigationTitle(details?.title ?? item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            // The backdrop sits in an overlay so its fill size never widens the page.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .overlay {
                    CachedImage(url: details?.backdropURL, contentMode: .fill) {
                        LinearGradient(colors: [item.mediaType.kind.tint.opacity(0.5), Theme.background],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .clipped()
            .overlay {
                LinearGradient(colors: [.clear, Theme.background.opacity(0.75), Theme.background],
                               startPoint: .center, endPoint: .bottom)
            }

            HStack(alignment: .bottom, spacing: 14) {
                PosterImage(url: details?.posterURL ?? item.posterURL, title: item.title, kind: item.mediaType.kind)
                    .frame(width: 104)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(details?.title ?? item.title)
                        .font(.title2.bold())
                        .lineLimit(3)
                    Text(metaLine).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        MediaChip(text: item.mediaType.label, compact: true)
                        if let state { StatusBadge(state: state) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .offset(y: 20)
        }
        .padding(.bottom, 20)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = details?.year ?? item.year { parts.append(year) }
        if let runtime = details?.runtime, runtime > 0 {
            parts.append(isTV ? String(localized: "\(runtime) min / episode") : String(localized: "\(runtime / 60) h \(runtime % 60) min"))
        }
        if let genres = details?.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tagline = details?.tagline {
                Text(tagline).font(.subheadline.italic()).foregroundStyle(.secondary)
            }
            if let text = details?.overview ?? item.overview, !text.isEmpty {
                Text(text).font(.subheadline)
            }
        }
    }

    // MARK: Seasons & episodes

    private func seasonsSection(_ seasons: [SeerrSeason]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { season in
                        Button { shownSeason = season.number } label: {
                            HStack(spacing: 6) {
                                if let state = season.state {
                                    Circle().fill(state.color).frame(width: 7, height: 7)
                                }
                                (season.number == 0 ? Text("Specials") : Text("Season \(season.number)"))
                                    .font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .foregroundStyle(shownSeason == season.number ? Color.white : Color.primary)
                            .background(shownSeason == season.number ? Theme.accent.opacity(0.85) : Theme.card, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()

            if let number = shownSeason, let season = seasons.first(where: { $0.number == number }) {
                Text([season.state?.label, String(localized: "\(season.episodeCount) episodes"), season.airYear].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                episodeList(for: number)
            }
        }
        .task(id: shownSeason) { await loadEpisodes() }
    }

    @ViewBuilder private func episodeList(for season: Int) -> some View {
        if let list = episodes[season] {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, episode in
                    if index > 0 { Divider().overlay(Color.white.opacity(0.06)) }
                    EpisodeRow(episode: episode)
                }
            }
            .padding(.horizontal, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    // MARK: Request

    @ViewBuilder private var requestSection: some View {
        if didRequest {
            Label("Requested", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.online)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if canRequest {
            VStack(alignment: .leading, spacing: 14) {
                Text("Request Title").font(.title3.bold())

                VStack(alignment: .leading, spacing: 12) {
                    if isTV { seasonPicker }
                    if !servers.isEmpty {
                        if servers.count > 1 {
                            OptionRow(title: isTV ? "Sonarr Server" : "Radarr Server") {
                                Picker("Server", selection: $serverID) {
                                    ForEach(servers) { server in
                                        Text(server.is4k ? "\(server.name) (4K)" : server.name).tag(Optional(server.id))
                                    }
                                }
                            }
                        }
                        if let server, !server.profiles.isEmpty {
                            OptionRow(title: "Quality Profile") {
                                Picker("Quality Profile", selection: $profileID) {
                                    ForEach(server.profiles) { profile in
                                        Text(profile.id == server.defaultProfileID ? "\(profile.name) (Default)" : profile.name)
                                            .tag(Optional(profile.id))
                                    }
                                }
                            }
                        }
                    }
                }
                .card(padding: 14)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await request() }
                } label: {
                    HStack {
                        if isRequesting { ProgressView().tint(.white) }
                        Text(requestTitle)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .disabled(isRequesting || (isTV && selectedSeasons.isEmpty))
            }
        }
    }

    private var seasonPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Seasons to request").font(.subheadline.weight(.semibold))
                Spacer()
                Button(selectedSeasons.count == requestableSeasons.count ? String(localized: "None") : String(localized: "All")) {
                    selectedSeasons = selectedSeasons.count == requestableSeasons.count ? [] : Set(requestableSeasons.map(\.number))
                }
                .font(.subheadline)
            }
            ForEach(requestableSeasons) { season in
                Button {
                    if selectedSeasons.contains(season.number) { selectedSeasons.remove(season.number) } else { selectedSeasons.insert(season.number) }
                } label: {
                    HStack {
                        Image(systemName: selectedSeasons.contains(season.number) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedSeasons.contains(season.number) ? Theme.accent : Color.secondary)
                        Text("Season \(season.number)")
                        Spacer()
                        Text("\(season.episodeCount) episodes").font(.footnote).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Color.white.opacity(0.06))
        }
    }

    private var requestTitle: String {
        guard isTV else { return String(localized: "Request Movie") }
        let count = selectedSeasons.count
        return count == requestableSeasons.count && count > 1 ? String(localized: "Request All \(count) Seasons")
            : count == 1 ? String(localized: "Request 1 Season") : String(localized: "Request \(count) Seasons")
    }

    // MARK: Loading

    private func load() async {
        guard let service else { return }
        async let detailsCall = try? service.details(item.mediaType, tmdbID: item.tmdbID)
        async let ratingsCall = try? service.ratings(item.mediaType, tmdbID: item.tmdbID)
        async let serversCall = try? service.arrServers(for: item.mediaType)
        let (loadedDetails, loadedRatings, loadedServers) = await (detailsCall, ratingsCall, serversCall)
        details = loadedDetails
        ratings = loadedRatings ?? SeerrRatings()
        servers = loadedServers ?? []
        if let first = servers.first {
            serverID = first.id
            profileID = first.defaultProfileID ?? first.profiles.first?.id
        }
        if let seasons = loadedDetails?.seasons {
            selectedSeasons = Set(requestableSeasons.map(\.number))
            // Open the newest season that has episodes on TMDB.
            shownSeason = seasons.filter { $0.number > 0 && $0.episodeCount > 0 }.map(\.number).max() ?? seasons.first?.number
        }
    }

    private func loadEpisodes() async {
        guard let season = shownSeason, episodes[season] == nil, let service else { return }
        episodes[season] = (try? await service.episodes(tmdbID: item.tmdbID, season: season)) ?? []
    }

    private func request() async {
        guard let service else { return }
        isRequesting = true
        defer { isRequesting = false }
        var options = SeerrRequestOptions()
        if isTV { options.seasons = selectedSeasons.sorted() }
        options.server = server
        options.profileID = profileID
        do {
            try await service.request(item, options: options)
            withAnimation { didRequest = true }
            errorMessage = nil
            onRequested()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Building blocks

/// Label above a full-width menu picker, so long names like "[German] HD Bluray + WEB" fit on one line.
private struct OptionRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            content
                .pickerStyle(.menu)
                .labelsHidden()
                .padding(.leading, -12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RatingsRow: View {
    let ratings: SeerrRatings
    let tmdbScore: Double?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let score = ratings.imdbScore {
                    RatingTile(badge: "IMDb", badgeColor: Color(red: 0.96, green: 0.77, blue: 0.09), badgeText: .black,
                               value: String(format: "%.1f", score), caption: ratings.imdbVotes.map { String(localized: "\(Self.compact($0)) votes") } ?? "/ 10",
                               link: ratings.imdbURL)
                }
                if let critics = ratings.criticsScore {
                    RatingTile(badge: critics >= 60 ? "🍅" : "🤢", badgeColor: .clear, badgeText: .primary,
                               value: "\(critics)%", caption: ratings.criticsRating ?? String(localized: "Critics"), link: ratings.rottenTomatoesURL)
                }
                if let audience = ratings.audienceScore {
                    RatingTile(badge: "🍿", badgeColor: .clear, badgeText: .primary,
                               value: "\(audience)%", caption: String(localized: "Audience"), link: ratings.rottenTomatoesURL)
                }
                if let tmdbScore {
                    RatingTile(badge: "TMDB", badgeColor: Color(red: 0.01, green: 0.82, blue: 0.75), badgeText: .black,
                               value: String(format: "%.1f", tmdbScore), caption: "/ 10", link: nil)
                }
            }
        }
        .scrollClipDisabled()
    }

    private static func compact(_ number: Int) -> String {
        number >= 1_000_000 ? String(format: "%.1fM", Double(number) / 1_000_000)
            : number >= 1_000 ? "\(number / 1_000)K" : "\(number)"
    }
}

private struct RatingTile: View {
    let badge: String
    let badgeColor: Color
    let badgeText: Color
    let value: String
    let caption: String
    let link: URL?

    var body: some View {
        let tile = HStack(spacing: 10) {
            Text(badge)
                .font(.caption.weight(.heavy))
                .foregroundStyle(badgeText)
                .padding(.horizontal, badgeColor == .clear ? 0 : 6)
                .padding(.vertical, 3)
                .background(badgeColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .font(badgeColor == .clear ? .title3 : .caption.weight(.heavy))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline).monospacedDigit()
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        if let link {
            Link(destination: link) { tile }.buttonStyle(.plain)
        } else {
            tile
        }
    }
}

private struct EpisodeRow: View {
    let episode: SeerrEpisode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedImage(url: episode.stillURL, contentMode: .fill) {
                Rectangle().fill(Theme.tile).overlay {
                    Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(episode.number). \(episode.name)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let date = episode.airDate {
                    Text(date > .now ? String(localized: "Airs \(date.formatted(date: .abbreviated, time: .omitted))")
                                     : date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(date > .now ? Theme.accent : .secondary)
                }
                if let overview = episode.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Streaming

/// "Streaming in Germany: Netflix, Prime Video" – or a note that it isn't included anywhere yet.
/// Loaded through Seerr (TMDB watch providers, data by JustWatch) for the device's country.
struct StreamingAvailabilityView: View {
    @Environment(SeerrStore.self) private var seerr
    let type: SeerrMediaType
    let tmdbID: Int

    @State private var availability: StreamingAvailability?
    @State private var failed = false

    static var region: String { Locale.current.region?.identifier ?? "DE" }
    private var regionName: String {
        Locale.current.localizedString(forRegionCode: Self.region) ?? Self.region
    }

    var body: some View {
        Group {
            if let availability {
                content(availability)
            } else if failed {
                Label("Streaming availability couldn't be loaded.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking streaming services…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: tmdbID) { await load() }
    }

    @ViewBuilder private func content(_ availability: StreamingAvailability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if availability.subscription.isEmpty {
                Label("Not included with any streaming service in \(regionName) yet.", systemImage: "tv.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label("Streaming in \(regionName)", systemImage: "play.tv.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.online)
                ProviderLogos(providers: availability.subscription)
            }
            if !availability.purchase.isEmpty {
                Text("To buy: \(availability.purchase.prefix(4).map(\.name).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Streaming data: JustWatch")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func load() async {
        guard let client = seerr.client else { failed = true; return }
        do {
            availability = try await client.streaming(type, tmdbID: tmdbID, region: Self.region)
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}

private struct ProviderLogos: View {
    let providers: [StreamingProvider]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(providers) { provider in
                    HStack(spacing: 8) {
                        CachedImage(url: provider.logoURL) {
                            Image(systemName: "play.rectangle.fill").foregroundStyle(.secondary)
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(provider.name)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
                    .background(Theme.tile, in: Capsule())
                }
            }
        }
    }
}
