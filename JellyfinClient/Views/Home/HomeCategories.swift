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
        ]
    }

    /// The rows in a different order every day (like Netflix rearranging its Home screen), the same all day.
    static var forToday: [HomeCategory] {
        var rows = all
        var seed = UInt64(Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 1)
        for index in stride(from: rows.count - 1, to: 0, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            rows.swapAt(index, Int((seed >> 33) % UInt64(index + 1)))
        }
        return rows
    }
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

/// The rows below "Recently Added": Jellyfin's suggestions from the library mixed with Netflix-style
/// categories from Seerr. Without Seerr, rows of the library's own genres instead. Rows load when they
/// scroll into view.
struct HomeCategoriesSection: View {
    @Environment(SeerrStore.self) private var seerr

    let api: JellyfinAPI?
    let onOpenItem: (BaseItem) -> Void
    let onOpenSeerr: (DiscoverItem) -> Void

    @State private var recommendations: [Recommendation] = []
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
        let library = recommendations.enumerated().compactMap { index, recommendation -> Row? in
            guard recommendation.items.count >= 4 else { return nil }
            return .library(id: recommendation.categoryId ?? "\(index)", title: Self.title(for: recommendation),
                            items: recommendation.items)
        }
        guard seerr.isConnected else {
            return library + genreRows.map { .library(id: "genre-\($0.title)", title: $0.title, items: $0.items) }
        }
        // A library suggestion after every third Seerr row.
        var result: [Row] = []
        var pending = library[...]
        for (index, category) in HomeCategories.forToday.enumerated() {
            result.append(.seerr(category))
            if index % 3 == 1, let next = pending.popFirst() { result.append(next) }
        }
        return result + pending
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            ForEach(rows) { row in
                switch row {
                case .library(_, let title, let items):
                    HomeRowContainer(title: title) {
                        ForEach(items) { item in
                            Button { onOpenItem(item) } label: { PosterCard(item: item).frame(width: 118) }
                                .buttonStyle(.plain)
                        }
                    }
                case .seerr(let category):
                    HomeSeerrCategoryRow(category: category, onOpen: open)
                }
            }
        }
        .task(id: api?.userId) { await loadLibraryRows() }
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

    private func loadLibraryRows() async {
        guard let api else { return }
        recommendations = (try? await api.movieRecommendations()) ?? []
        guard !seerr.isConnected else { return }
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

    private static func title(for recommendation: Recommendation) -> String {
        let name = recommendation.baselineItemName ?? ""
        switch recommendation.recommendationType {
        case "SimilarToRecentlyPlayed": return String(localized: "Because You Watched “\(name)”")
        case "SimilarToLikedItem": return String(localized: "Because You Liked “\(name)”")
        case "HasDirectorFromRecentlyPlayed", "HasLikedDirector": return String(localized: "Directed by \(name)")
        case "HasActorFromRecentlyPlayed", "HasLikedActor": return String(localized: "Starring \(name)")
        default: return name
        }
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
            if let items, items.count >= 5 {
                HomeRowContainer(title: category.title) {
                    ForEach(items) { item in
                        Button { onOpen(item) } label: { HomeDiscoverCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
            } else {
                // Keeps the lazy stack loading rows as you scroll, without leaving gaps.
                Color.clear.frame(height: items == nil ? 1 : 0)
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

/// Poster and title of a TMDB title; a green dot when it's in the library.
private struct HomeDiscoverCard: View {
    let item: DiscoverItem

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
