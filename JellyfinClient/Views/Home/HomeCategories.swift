import SwiftUI

// MARK: - Categories

/// A Netflix-style row on the Home screen, filled from Seerr's discover endpoint (TMDB). One row can
/// combine a movie and a series query; their results are interleaved.
struct HomeCategory: Identifiable {
    struct Query {
        var type: SeerrMediaType
        var filters: [(String, String)] = []
        /// TMDB keyword looked up by name at runtime (ids are resolved once and remembered).
        var keyword: String?
    }

    let id: String
    let title: LocalizedStringKey
    let queries: [Query]
}

enum HomeCategories {
    private static func date(yearsAgo years: Int) -> String {
        let date = Calendar.current.date(byAdding: .year, value: -years, to: .now) ?? .now
        return date.formatted(.iso8601.year().month().day())
    }

    /// All rows backed by Seerr. Original language uses Seerr's `language` filter.
    static var all: [HomeCategory] {
        let popular = ("sortBy", "popularity.desc")
        return [
            HomeCategory(id: "hits", title: "Audience Favorites", queries: [
                .init(type: .movie, filters: [popular, ("voteCountGte", "1500")])]),
            HomeCategory(id: "us-series", title: "US Series", queries: [
                .init(type: .tv, filters: [popular, ("language", "en"), ("voteCountGte", "300")])]),
            HomeCategory(id: "true-stories", title: "True Stories", queries: [
                .init(type: .movie, filters: [popular, ("voteCountGte", "200")], keyword: "based on true story"),
                .init(type: .tv, filters: [popular, ("voteCountGte", "50")], keyword: "based on true story")]),
            HomeCategory(id: "anime", title: "Anime", queries: [
                .init(type: .tv, filters: [popular, ("genre", "16"), ("language", "ja"), ("voteCountGte", "100")])]),
            HomeCategory(id: "teen", title: "Teen Series", queries: [
                .init(type: .tv, filters: [popular, ("voteCountGte", "100")], keyword: "high school")]),
            HomeCategory(id: "action", title: "Action Movies", queries: [
                .init(type: .movie, filters: [popular, ("genre", "28"), ("voteCountGte", "500")])]),
            HomeCategory(id: "classics", title: "Series That Still Impress 10 Years Later", queries: [
                .init(type: .tv, filters: [("sortBy", "vote_average.desc"), ("voteCountGte", "1500"),
                                           ("firstAirDateLte", date(yearsAgo: 10)), ("firstAirDateGte", date(yearsAgo: 25))])]),
            HomeCategory(id: "rewatch", title: "Cult Series Everyone Knows", queries: [
                .init(type: .tv, filters: [("sortBy", "vote_count.desc")])]),
            HomeCategory(id: "thrilling", title: "Exciting Series", queries: [
                .init(type: .tv, filters: [popular, ("genre", "10759"), ("voteCountGte", "300")])]),
            HomeCategory(id: "comedy-tv", title: "For Fun Nights with Friends", queries: [
                .init(type: .tv, filters: [popular, ("genre", "35"), ("voteCountGte", "300")])]),
            HomeCategory(id: "thriller", title: "Gripping Thrillers", queries: [
                .init(type: .movie, filters: [popular, ("genre", "53"), ("voteCountGte", "500")])]),
            HomeCategory(id: "crime", title: "Crime Series", queries: [
                .init(type: .tv, filters: [popular, ("genre", "80"), ("voteCountGte", "300")])]),
            HomeCategory(id: "german", title: "Made in Germany", queries: [
                .init(type: .movie, filters: [popular, ("language", "de"), ("voteCountGte", "100")]),
                .init(type: .tv, filters: [popular, ("language", "de"), ("voteCountGte", "30")])]),
            HomeCategory(id: "korean", title: "Korean Series", queries: [
                .init(type: .tv, filters: [popular, ("language", "ko"), ("voteCountGte", "100")])]),
            HomeCategory(id: "family", title: "Animated Movies for the Whole Family", queries: [
                .init(type: .movie, filters: [popular, ("genre", "16,10751"), ("voteCountGte", "500")])]),
            HomeCategory(id: "horror", title: "Goosebumps Guaranteed", queries: [
                .init(type: .movie, filters: [popular, ("genre", "27"), ("voteCountGte", "500")])]),
            HomeCategory(id: "scifi", title: "Sci-Fi & Fantasy Series", queries: [
                .init(type: .tv, filters: [popular, ("genre", "10765"), ("voteCountGte", "300")])]),
            HomeCategory(id: "docs", title: "Documentaries That Move You", queries: [
                .init(type: .movie, filters: [popular, ("genre", "99"), ("voteCountGte", "100")]),
                .init(type: .tv, filters: [popular, ("genre", "99"), ("voteCountGte", "50")])]),
            HomeCategory(id: "scifi-movies", title: "Mind-Bending Sci-Fi Movies", queries: [
                .init(type: .movie, filters: [popular, ("genre", "878"), ("voteCountGte", "1000")])]),
            HomeCategory(id: "romance", title: "Romantic Movies", queries: [
                .init(type: .movie, filters: [popular, ("genre", "10749"), ("voteCountGte", "500")])]),
            HomeCategory(id: "comedy-movies", title: "Comedies to Unwind", queries: [
                .init(type: .movie, filters: [popular, ("genre", "35"), ("voteCountGte", "800")])]),
            HomeCategory(id: "mystery", title: "Mysterious Series", queries: [
                .init(type: .tv, filters: [popular, ("genre", "9648"), ("voteCountGte", "200")])]),
            HomeCategory(id: "superheroes", title: "Superhero Movies", queries: [
                .init(type: .movie, filters: [popular, ("voteCountGte", "1000")], keyword: "superhero")]),
            HomeCategory(id: "hidden-gems", title: "Hidden Gems", queries: [
                .init(type: .movie, filters: [("sortBy", "vote_average.desc"), ("voteAverageGte", "7.5"),
                                              ("voteCountGte", "300"), ("voteCountLte", "3000")])]),
            HomeCategory(id: "nineties", title: "Cult Classics from the 90s", queries: [
                .init(type: .movie, filters: [("sortBy", "vote_count.desc"),
                                              ("primaryReleaseDateGte", "1990-01-01"), ("primaryReleaseDateLte", "1999-12-31")])]),
            HomeCategory(id: "miniseries", title: "Miniseries for One Weekend", queries: [
                .init(type: .tv, filters: [popular, ("voteCountGte", "100")], keyword: "miniseries")]),
        ]
    }

    /// The rows in a new random order on every app launch (like Netflix rearranging its Home screen),
    /// kept while the app runs so the screen doesn't jump around.
    static let shuffledForLaunch: [HomeCategory] = all.shuffled()
}

// MARK: - Loading

/// Fetches and remembers the category rows for the session, so going back to Home doesn't reload them.
actor HomeCategoryStore {
    static let shared = HomeCategoryStore()

    private var items: [String: (date: Date, items: [DiscoverItem])] = [:]
    private var keywordIDs: [String: Int] = (UserDefaults.standard.dictionary(forKey: "home.keywordIDs") as? [String: Int]) ?? [:]

    func items(for category: HomeCategory, client: SeerrClient) async -> [DiscoverItem] {
        if let cached = items[category.id], Date.now.timeIntervalSince(cached.date) < 3600 { return cached.items }
        var lists: [[DiscoverItem]] = []
        for query in category.queries {
            var filters = query.filters
            if let keyword = query.keyword {
                guard let id = await keywordID(keyword, client: client) else { continue }
                filters.append(("keywords", String(id)))
            }
            lists.append((try? await client.discover(query.type, filters: filters)) ?? [])
        }
        // Interleave movies and series, each title once.
        var result: [DiscoverItem] = []
        var seen = Set<String>()
        for index in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where index < list.count && seen.insert(list[index].id).inserted {
                result.append(list[index])
            }
        }
        result = Array(result.prefix(20))
        if !result.isEmpty { items[category.id] = (.now, result) }
        return result
    }

    private func keywordID(_ name: String, client: SeerrClient) async -> Int? {
        if let id = keywordIDs[name] { return id }
        guard let found = try? await client.keywordID(name) else { return nil }
        keywordIDs[name] = found
        UserDefaults.standard.set(keywordIDs, forKey: "home.keywordIDs")
        return found
    }
}

// MARK: - Views

/// The rows below "Recently Added": Netflix-style categories from Seerr. Without Seerr, rows of the
/// library's own genres instead. Rows load when they scroll into view.
struct HomeCategoriesSection: View {
    @Environment(SeerrStore.self) private var seerr

    let api: JellyfinAPI?
    let onOpenItem: (BaseItem) -> Void
    let onOpenSeerr: (DiscoverItem) -> Void

    @State private var genreRows: [(title: String, items: [BaseItem])] = []

    private enum Row: Identifiable {
        case library(id: String, title: String, items: [BaseItem])
        case seerr(HomeCategory)
        var id: String {
            switch self {
            case .library(let id, _, _): "library-\(id)"
            case .seerr(let category): "seerr-\(category.id)"
            }
        }
    }

    private var rows: [Row] {
        guard seerr.isConnected else {
            return genreRows.map { .library(id: "genre-\($0.title)", title: $0.title, items: $0.items) }
        }
        return HomeCategories.shuffledForLaunch.map { .seerr($0) }
    }

    var body: some View {
        // No stack spacing: each visible row adds the gap below itself, so rows that load or stay empty
        // never leave extra space.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                switch row {
                case .library(_, let title, let items):
                    HomeRowContainer(title: title) {
                        ForEach(items) { item in
                            Button { onOpenItem(item) } label: { PosterCard(item: item).frame(width: 118) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, HomeLayout.rowSpacing)
                case .seerr(let category):
                    HomeSeerrCategoryRow(category: category, onOpen: open)
                }
            }
        }
        .task(id: "\(api?.userId ?? "")-\(seerr.isConnected)") { await loadGenreRows() }
    }

    /// Available titles open their page in the library; the rest open Seerr to request them.
    private func open(_ item: DiscoverItem) {
        guard item.state == .available || item.state == .partiallyAvailable, let api else {
            onOpenSeerr(item)
            return
        }
        Task {
            if let libraryItem = await api.libraryItem(tmdbID: item.tmdbID, title: item.title, isSeries: item.mediaType == .tv) {
                onOpenItem(libraryItem)
            } else {
                onOpenSeerr(item)
            }
        }
    }

    private func loadGenreRows() async {
        guard let api, !seerr.isConnected else { return }
        // Without Seerr: the library's biggest genres, two from movies and two from series.
        var rows: [(String, [BaseItem])] = []
        for (type, label) in [("Movie", String(localized: "Movies")), ("Series", String(localized: "Series"))] {
            let genres = ((try? await api.genres(itemType: type)) ?? [])
                .sorted { ($0.movieCount ?? $0.seriesCount ?? 0) > ($1.movieCount ?? $1.seriesCount ?? 0) }
            for genre in genres.prefix(3) {
                guard let name = genre.name else { continue }
                let items = (try? await api.items(genre: name, itemType: type)) ?? []
                if items.count >= 4 { rows.append(("\(name) · \(label)", items)) }
            }
        }
        genreRows = rows
    }
}

/// A Seerr category: hidden until it has loaded at least a handful of titles.
private struct HomeSeerrCategoryRow: View {
    @Environment(SeerrStore.self) private var seerr
    let category: HomeCategory
    let onOpen: (DiscoverItem) -> Void

    @State private var items: [DiscoverItem]?

    var body: some View {
        Group {
            if let items {
                if items.count >= 5 {
                    HomeRowContainer(title: category.title) {
                        ForEach(items) { item in
                            Button { onOpen(item) } label: { HomeDiscoverCard(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, HomeLayout.rowSpacing)
                } else {
                    Color.clear.frame(height: 0)    // nothing worth showing: takes no space at all
                }
            } else {
                // While loading: a placeholder of the final size, so nothing jumps when it arrives.
                HomeRowContainer(title: category.title) {
                    ForEach(0..<4, id: \.self) { _ in HomeDiscoverCard.placeholder }
                }
                .redacted(reason: .placeholder)
                .allowsHitTesting(false)
                .padding(.bottom, HomeLayout.rowSpacing)
            }
        }
        .task {
            guard items == nil, let client = seerr.client else { return }
            items = await HomeCategoryStore.shared.items(for: category, client: client)
        }
    }
}

/// Section title and a horizontally scrolling row, like the other Home rows.
struct HomeRowContainer<Content: View>: View {
    let title: Text
    @ViewBuilder let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = Text(title)
        self.content = content
    }

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = Text(verbatim: title)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title
                .font(.title2.bold())
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal)
            }
        }
    }
}

/// Spacing shared by all Home sections.
enum HomeLayout {
    static let rowSpacing: CGFloat = 24
}

/// Poster and title of a TMDB title; a green dot when it's in the library.
private struct HomeDiscoverCard: View {
    let item: DiscoverItem

    /// Same size as a loaded card, for rows that are still loading.
    static var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.18))
                .aspectRatio(2 / 3, contentMode: .fit)
            Text(verbatim: "Placeholder title").font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(verbatim: "2000").font(.caption)
        }
        .frame(width: 118)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: item.posterURL, title: item.title, kind: item.mediaType.kind)
                .overlay(alignment: .topTrailing) {
                    if let state = item.state, state == .available || state == .partiallyAvailable {
                        Circle()
                            .fill(state.color)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1.5))
                            .padding(7)
                            .accessibilityLabel(state.label)
                    }
                }
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let year = item.year {
                Text(year).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 118)
    }
}
