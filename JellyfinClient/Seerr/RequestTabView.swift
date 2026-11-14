import SwiftUI

enum DiscoverMediaFilter: String, CaseIterable, Identifiable {
    case all, movies, series
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        }
    }

    func allows(_ type: SeerrMediaType) -> Bool {
        switch self {
        case .all: true
        case .movies: type == .movie
        case .series: type == .tv
        }
    }
}

/// Pushed screens of the Request tab.
enum SeerrRoute: Hashable {
    case requests
}

/// "Request" tab – Seerr discovery exactly like in the Servarr app: filter bar, requests, networks,
/// rows for trending/popular/upcoming/top rated and genres, each opening a full list with paging and filters.
struct RequestTabView: View {
    @Environment(SeerrStore.self) private var seerr
    @AppStorage("discover.filter") private var filter: DiscoverMediaFilter = .all
    @AppStorage("discover.hideAvailable") private var hideAvailable = false

    @State private var query = ""
    @State private var rows: [DiscoverQuery: [DiscoverItem]] = [:]
    @State private var networks: [SeerrNetwork] = DiscoverNetworks.all.map { SeerrNetwork(id: $0.id, name: $0.name, logoURL: nil) }
    @State private var movieGenres: [SeerrGenre] = []
    @State private var tvGenres: [SeerrGenre] = []
    @State private var results: [DiscoverItem] = []
    @State private var pendingCount = 0
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var selected: DiscoverItem?
    /// The Seerr server the rows were loaded from – switching setups starts from a clean slate.
    @State private var loadedConfig: SeerrConfig?
    /// Lets the filter menu open a genre list.
    @State private var path = NavigationPath()

    private var client: SeerrClient? { seerr.client }

    // MARK: Rows

    private static let trending = DiscoverQuery(source: .trending, title: String(localized: "Trending"))
    private static let popularMovies = DiscoverQuery(source: .movies, title: String(localized: "Popular Movies"))
    private static let popularSeries = DiscoverQuery(source: .tv, title: String(localized: "Popular Series"))
    private static let upcomingMovies = DiscoverQuery(source: .upcomingMovies, title: String(localized: "Upcoming Movies"))
    private static let upcomingSeries = DiscoverQuery(source: .upcomingTV, title: String(localized: "Upcoming Series"))
    private static let topMovies = DiscoverQuery(source: .movies, title: String(localized: "Top Rated Movies"), sort: .rating)
    private static let topSeries = DiscoverQuery(source: .tv, title: String(localized: "Top Rated Series"), sort: .rating)
    private static let allRows = [trending, popularMovies, popularSeries, upcomingMovies, upcomingSeries, topMovies, topSeries]

    private func visible(_ row: DiscoverQuery) -> Bool {
        guard let type = row.mediaType else { return true }
        return filter.allows(type)
    }

    private func items(for row: DiscoverQuery) -> [DiscoverItem] {
        (rows[row] ?? []).filter { filter.allows($0.mediaType) && !(hideAvailable && $0.isAvailable) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !seerr.isConnected {
                    SeerrNotConnectedView()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            filterBar
                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .card(padding: 14)
                            }
                            if query.isEmpty {
                                requestsLink
                                discoverContent
                            } else {
                                searchResults
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .themedBackground()
                    .toolbar { filterMenu }
                    .searchable(text: $query, prompt: "Movies & Series")
                    .task(id: query) {
                        try? await Task.sleep(for: .milliseconds(350)) // debounce typing
                        guard !Task.isCancelled else { return }
                        await search()
                    }
                    .task(id: seerr.config) { await loadAll() }
                    .refreshable { await loadAll() }
                    .navigationDestination(for: DiscoverQuery.self) { query in
                        DiscoverListView(query: query)
                    }
                    .navigationDestination(for: SeerrRoute.self) { route in
                        if case .requests = route { SeerrRequestsView() }
                    }
                    .navigationDestination(item: $selected) { item in
                        SeerrTitleDetailView(item: item) { Task { await loadAll() } }
                    }
                }
            }
            .navigationTitle("Request")
            .themedBackground()
            .appTopActions()
        }
    }

    // MARK: Sections

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DiscoverMediaFilter.allCases) { option in
                    FilterChip(title: option.label, isOn: filter == option) {
                        withAnimation(.snappy) { filter = option }
                    }
                }
                if hideAvailable {
                    FilterChip(title: String(localized: "Hiding Available"), systemImage: "xmark", isOn: true) {
                        withAnimation(.snappy) { hideAvailable = false }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder private var discoverContent: some View {
        // Networks first, right under the Requests button (series only, so hidden for "Movies").
        if filter != .movies {
            networksSection
        }
        ForEach(Self.allRows.filter(visible), id: \.self) { row in
            DiscoverRow(query: row, items: items(for: row), isLoading: rows[row] == nil) { selected = $0 }
        }
    }

    /// Top-right filter: hide what you already have, or open a genre list.
    private var filterMenu: some View {
        Menu {
            Toggle("Hide Available", systemImage: "eye.slash", isOn: $hideAvailable.animation(.snappy))
            if filter != .series && !movieGenres.isEmpty {
                Menu("Movie Genres", systemImage: "film") {
                    ForEach(movieGenres) { genre in
                        Button(genre.name) { path.append(DiscoverQuery(source: .movies, title: genre.name, genre: genre)) }
                    }
                }
            }
            if filter != .movies && !tvGenres.isEmpty {
                Menu("Series Genres", systemImage: "tv") {
                    ForEach(tvGenres) { genre in
                        Button(genre.name) { path.append(DiscoverQuery(source: .tv, title: genre.name, genre: genre)) }
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
    }

    private var networksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Networks").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(networks, id: \.id) { network in
                        NavigationLink(value: DiscoverQuery(source: .tv, title: network.name, networkID: network.id)) {
                            NetworkTile(network: network)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var requestsLink: some View {
        NavigationLink(value: SeerrRoute.requests) {
            HStack(spacing: 14) {
                ServiceIcon(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Requests").font(.headline)
                    Text(pendingCount == 0 ? "Nothing waiting for approval" : "\(pendingCount) waiting for approval")
                        .font(.subheadline)
                        .foregroundStyle(pendingCount == 0 ? Color.secondary : Color.orange)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var searchResults: some View {
        let visibleResults = results.filter { filter.allows($0.mediaType) && !(hideAvailable && $0.isAvailable) }
        if isSearching && results.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if visibleResults.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            PosterGrid(items: visibleResults) { selected = $0 }
        }
    }

    // MARK: Loading

    private func loadAll() async {
        guard let client, let config = seerr.config else { return }
        if loadedConfig != config {
            loadedConfig = config
            rows = [:]
            results = []
            movieGenres = []
            tvGenres = []
            pendingCount = 0
            networks = DiscoverNetworks.all.map { SeerrNetwork(id: $0.id, name: $0.name, logoURL: nil) }
        }
        let service = client
        await withTaskGroup(of: Void.self) { group in
            for row in Self.allRows {
                group.addTask {
                    let page = try? await service.discover(row, page: 1)
                    await MainActor.run { rows[row] = page?.items ?? rows[row] ?? [] }
                }
            }
            group.addTask {
                async let movie = try? service.genres(.movie)
                async let tv = try? service.genres(.tv)
                let (m, t) = await (movie, tv)
                await MainActor.run {
                    movieGenres = m ?? movieGenres
                    tvGenres = t ?? tvGenres
                }
            }
            group.addTask {
                let requests = try? await service.requests()
                await MainActor.run {
                    if let requests { pendingCount = requests.filter { $0.state == .pendingApproval }.count }
                }
            }
            for network in DiscoverNetworks.all {
                group.addTask {
                    guard let info = try? await service.network(id: network.id) else { return }
                    await MainActor.run {
                        if let index = networks.firstIndex(where: { $0.id == info.id }) { networks[index] = info }
                    }
                }
            }
        }
        errorMessage = rows.values.allSatisfy(\.isEmpty) ? String(localized: "Couldn't load from Seerr. Pull to try again.") : nil
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let client, !trimmed.isEmpty else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await client.search(trimmed)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension DiscoverItem {
    var isAvailable: Bool { state == .available || state == .partiallyAvailable }
}

// MARK: - Building blocks

private struct FilterChip: View {
    let title: String
    var systemImage: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.caption.weight(.semibold)) }
                Text(title).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? Theme.accent.opacity(0.85) : Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// "Title >   See All >" with a horizontal poster row.
private struct DiscoverRow: View {
    let query: DiscoverQuery
    let items: [DiscoverItem]
    let isLoading: Bool
    let onSelect: (DiscoverItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(query.title, destination: query)
            if isLoading {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.card)
                                .frame(width: 112, height: 168)
                        }
                    }
                }
            } else if items.isEmpty {
                Text("Nothing here right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items.prefix(20)) { item in
                            Button { onSelect(item) } label: {
                                SeerrPosterCard(url: item.posterURL, title: item.title, kind: item.mediaType.kind,
                                           chip: item.mediaType.label, footnote: item.year, badge: item.state)
                                    .frame(width: 112)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// Light rounded tile with the network's logo, like in Seerr.
private struct NetworkTile: View {
    let network: SeerrNetwork

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(white: 0.94))
            .frame(width: 150, height: 84)
            .overlay {
                CachedImage(url: network.logoURL) {
                    Text(network.name)
                        .font(.headline)
                        .foregroundStyle(.black.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
            }
            .accessibilityLabel(network.name)
    }
}

private struct PosterGrid: View {
    let items: [DiscoverItem]
    var onAppearLast: (() -> Void)?
    let onSelect: (DiscoverItem) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14, alignment: .top)], spacing: 20) {
            ForEach(items) { item in
                Button { onSelect(item) } label: {
                    SeerrPosterCard(url: item.posterURL, title: item.title, kind: item.mediaType.kind,
                               chip: item.mediaType.label, footnote: item.year, badge: item.state)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if item.id == items.last?.id { onAppearLast?() }
                }
            }
        }
    }
}

// MARK: - See All

/// A full discover list with endless scrolling; movie/series lists can be sorted and filtered by genre.
struct DiscoverListView: View {
    @Environment(SeerrStore.self) private var seerr
    @AppStorage("discover.hideAvailable") private var hideAvailable = false

    let query: DiscoverQuery
    @State private var sort: DiscoverSort
    @State private var genre: SeerrGenre?
    @State private var genres: [SeerrGenre] = []
    @State private var items: [DiscoverItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selected: DiscoverItem?

    init(query: DiscoverQuery) {
        self.query = query
        _sort = State(initialValue: query.sort)
        _genre = State(initialValue: query.genre)
    }

    private var effectiveQuery: DiscoverQuery {
        var copy = query
        copy.sort = sort
        copy.genre = genre
        return copy
    }

    private var visibleItems: [DiscoverItem] {
        hideAvailable ? items.filter { !$0.isAvailable } : items
    }

    private var title: String {
        guard let genre, query.genre == nil else { return query.title }
        return "\(query.title) · \(genre.name)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if query.networkID == NetflixTop10Section.netflixNetworkID {
                    NetflixTop10Section { selected = $0 }
                    Text("All Netflix Series").font(.title3.bold()).padding(.top, 8)
                }
                if query.isFilterable { activeFilters }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                PosterGrid(items: visibleItems, onAppearLast: { Task { await loadMore() } }) { selected = $0 }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if !items.isEmpty && visibleItems.isEmpty {
                    ContentUnavailableView("All Available", systemImage: "checkmark.circle",
                                           description: Text("Everything loaded so far is already in your library."))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { filterMenu }
        .task(id: "\(sort.rawValue)-\(genre?.id ?? -1)") { await reload() }
        .task { await loadGenres() }
        .refreshable { await reload() }
        .navigationDestination(item: $selected) { SeerrTitleDetailView(item: $0) }
    }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DiscoverSort.allCases) { option in
                    FilterChip(title: option.label, isOn: sort == option) { sort = option }
                }
                if let genre, query.genre == nil {
                    FilterChip(title: genre.name, systemImage: "xmark", isOn: true) { self.genre = nil }
                }
            }
        }
        .scrollClipDisabled()
    }

    private var filterMenu: some View {
        Menu {
            if query.isFilterable && query.genre == nil && !genres.isEmpty {
                Picker("Genre", selection: $genre) {
                    Text("All Genres").tag(SeerrGenre?.none)
                    ForEach(genres) { Text($0.name).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
            Toggle("Hide Available", systemImage: "eye.slash", isOn: $hideAvailable)
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
    }

    private func loadGenres() async {
        guard query.isFilterable, query.genre == nil, let client = seerr.client,
              let type = query.mediaType else { return }
        genres = (try? await client.genres(type)) ?? []
    }

    private func reload() async {
        items = []
        page = 0
        totalPages = 1
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, page < totalPages, let client = seerr.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await client.discover(effectiveQuery, page: page + 1)
            // TMDB pages can overlap while popularity shifts – keep the first occurrence.
            let known = Set(items.map(\.id))
            items += next.items.filter { !known.contains($0.id) }
            page += 1
            totalPages = next.totalPages
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Netflix Top 10

/// Netflix's weekly Top 10 (Germany, falling back to the global list), matched to Seerr titles
/// so posters, availability and the request button work as everywhere else.
private struct NetflixTop10Section: View {
    static let netflixNetworkID = 213

    @Environment(SeerrStore.self) private var seerr
    let onSelect: (DiscoverItem) -> Void

    @State private var list: Top10List?
    @State private var showSeries = true
    @State private var matches: [String: DiscoverItem] = [:]
    @State private var failed = false

    private var entries: [Top10Entry] { (showSeries ? list?.series : list?.movies) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top 10 This Week").font(.title3.bold())
                    if let list {
                        Text("\(Self.regionName(list.region)) · \(list.weekStart.formatted(.dateTime.day().month(.abbreviated))) – \(list.weekEnd.formatted(.dateTime.day().month(.abbreviated)))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    FilterChip(title: String(localized: "Series"), isOn: showSeries) { showSeries = true }
                    FilterChip(title: String(localized: "Movies"), isOn: !showSeries) { showSeries = false }
                }
            }

            if list == nil {
                if failed {
                    Text("Netflix's Top 10 couldn't be loaded right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(entries) { entry in
                            let item = matches[Self.key(entry)]
                            Button { if let item { onSelect(item) } } label: {
                                Top10Card(entry: entry, item: item)
                            }
                            .buttonStyle(.plain)
                            .disabled(item == nil)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task {
            do {
                list = try await NetflixTop10.load()
                await matchTitles()
            } catch {
                failed = true
            }
        }
    }

    private static func regionName(_ region: String) -> String {
        region == NetflixTop10.countryName ? String(localized: "Germany") : String(localized: "Global")
    }

    private static func key(_ entry: Top10Entry) -> String {
        "\(entry.isSeries ? "tv" : "movie")-\(entry.searchTitle.lowercased())"
    }

    /// Finds each title in Seerr once (Lupin Part 1–4 share one search).
    private func matchTitles() async {
        guard let list, let service = seerr.client else { return }
        var unique: [String: Top10Entry] = [:]
        for entry in list.series + list.movies where unique[Self.key(entry)] == nil { unique[Self.key(entry)] = entry }
        await withTaskGroup(of: (String, DiscoverItem?).self) { group in
            for (key, entry) in unique {
                group.addTask {
                    let results = (try? await service.search(entry.searchTitle)) ?? []
                    return (key, Self.bestMatch(for: entry, in: results))
                }
            }
            for await (key, item) in group {
                if let item { matches[key] = item }
            }
        }
    }

    /// Same type; exact title preferred, then the closest year, then Seerr's own order.
    nonisolated private static func bestMatch(for entry: Top10Entry, in results: [DiscoverItem]) -> DiscoverItem? {
        let type: SeerrMediaType = entry.isSeries ? .tv : .movie
        let candidates = results.filter { $0.mediaType == type }
        func normalized(_ text: String) -> String {
            text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber }
        }
        let wanted = normalized(entry.searchTitle)
        let exact = candidates.filter { normalized($0.title) == wanted }
        let pool = exact.isEmpty ? candidates : exact
        if !entry.isSeries, let year = entry.year {
            if let byYear = pool.first(where: { Int($0.year ?? "").map { abs($0 - year) <= 1 } ?? false }) { return byYear }
        }
        return pool.first
    }
}

/// Big rank number next to the poster, like Netflix's own Top 10 row.
private struct Top10Card: View {
    let entry: Top10Entry
    let item: DiscoverItem?

    /// Netflix labels are English ("Season 2", "Parts 1–4", "Limited Series"); show them in the app's language.
    static func localizedSeasonLabel(_ label: String) -> String {
        if label == "Limited Series" { return String(localized: "Limited Series") }
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return label }
        let rest = parts[1]
        switch parts[0] {
        case "Season": return String(localized: "Season \(rest)")
        case "Seasons": return String(localized: "Seasons \(rest)")
        case "Part": return String(localized: "Part \(rest)")
        case "Parts": return String(localized: "Parts \(rest)")
        case "Volume", "Vol.": return String(localized: "Volume \(rest)")
        case "Volumes": return String(localized: "Volumes \(rest)")
        default:
            // "3 seasons" from merged lists.
            if let count = Int(parts[0]), rest == "seasons" { return String(localized: "\(count) Seasons") }
            return label
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Text("\(entry.rank)")
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.32))
                .shadow(color: .black.opacity(0.4), radius: 2)
                .minimumScaleFactor(0.6)
                .frame(width: entry.rank == 10 ? 76 : 42, alignment: .trailing)
                .padding(.bottom, 52)
            SeerrPosterCard(url: item?.posterURL, title: entry.searchTitle,
                       kind: entry.isSeries ? .series : .movie,
                       chip: entry.seasonLabel.map(Self.localizedSeasonLabel) ?? (entry.isSeries ? SeerrMediaType.tv.label : SeerrMediaType.movie.label),
                       badge: item?.state)
                .frame(width: 104)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Number \(entry.rank): \(entry.title)")
    }
}
