import Foundation

/// Finds titles by topic, e.g. "Dinosaurier" → Jurassic Park.
///
/// TMDB tags titles with English keywords ("dinosaur", "time travel"). The search term is looked up in
/// Wikidata, which names almost every concept in every language, to get its English name – no language
/// pack or API key needed. With Seerr, TMDB's titles for those keywords are fetched (the library's own
/// copies are shown as such); without Seerr, the library is searched by tags, where Jellyfin keeps
/// TMDB's keywords.
@MainActor
enum KeywordSearch {
    struct Result {
        let term: String
        /// The TMDB keywords (or tags) that matched, e.g. ["dinosaur"].
        let keywords: [String]
        var library: [BaseItem]
        var requestable: [DiscoverItem]
        var isEmpty: Bool { library.isEmpty && requestable.isEmpty }
    }

    private static var englishCache: [String: [String]] = [:]

    static func search(_ term: String, api: JellyfinAPI?, client: SeerrClient?) async -> Result? {
        let words = term.split(separator: " ")
        guard term.count >= 3, words.count <= 3 else { return nil }
        let candidates = await englishTerms(for: term)
        guard !Task.isCancelled else { return nil }

        if let client {
            return await seerrSearch(term, candidates: candidates, api: api, client: client)
        }
        guard let api, let items = try? await api.items(tags: candidates), !items.isEmpty else { return nil }
        return Result(term: term, keywords: candidates, library: items, requestable: [])
    }

    // MARK: - Seerr (TMDB keywords)

    private static func seerrSearch(_ term: String, candidates: [String], api: JellyfinAPI?, client: SeerrClient) async -> Result? {
        // Keywords whose name is exactly one of the candidates: "dinosaur", not "dinosaur egg".
        var matched: [(id: Int, name: String)] = []
        await withTaskGroup(of: (Int, [(id: Int, name: String)]).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    let found = (try? await client.keywords(matching: candidate)) ?? []
                    return (index, found.filter { normalized($0.name) == normalized(candidate) })
                }
            }
            var byIndex: [Int: [(id: Int, name: String)]] = [:]
            for await (index, found) in group { byIndex[index] = found }
            for index in candidates.indices {
                for keyword in byIndex[index] ?? [] where !matched.contains(where: { $0.id == keyword.id }) {
                    matched.append(keyword)
                }
            }
        }
        let keywords = Array(matched.prefix(3))
        guard !keywords.isEmpty, !Task.isCancelled else { return nil }

        // Movies and series with any of the keywords (TMDB reads "|" as "or"), most popular first.
        let filter = [("keywords", keywords.map { String($0.id) }.joined(separator: "|"))]
        async let moviesRequest = client.discover(.movie, filters: filter)
        async let seriesRequest = client.discover(.tv, filters: filter)
        let movies = (try? await moviesRequest) ?? []
        let series = (try? await seriesRequest) ?? []
        var merged: [DiscoverItem] = []
        for index in 0..<max(movies.count, series.count) {
            if index < movies.count { merged.append(movies[index]) }
            if index < series.count { merged.append(series[index]) }
        }

        // Titles Seerr sees on the server open their library page; the rest can be requested.
        let available = merged.filter { $0.state == .available || $0.state == .partiallyAvailable }.prefix(12)
        var libraryCopies: [String: BaseItem] = [:]
        if let api {
            await withTaskGroup(of: (String, BaseItem?).self) { group in
                for item in available {
                    group.addTask {
                        (item.id, await api.libraryItem(tmdbID: item.tmdbID, title: item.title, isSeries: item.mediaType == .tv))
                    }
                }
                for await (id, copy) in group { if let copy { libraryCopies[id] = copy } }
            }
        }
        let library = merged.compactMap { libraryCopies[$0.id] }
        let requestable = merged.filter { libraryCopies[$0.id] == nil }
        let result = Result(term: term, keywords: keywords.map(\.name), library: library, requestable: requestable)
        return result.isEmpty ? nil : result
    }

    // MARK: - Translation (Wikidata)

    /// English names for the term, best first, plus the term itself (keywords like "zombie" are the
    /// same in both languages). At most four.
    static func englishTerms(for term: String) async -> [String] {
        let key = term.lowercased()
        if let cached = englishCache[key] { return cached }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        var terms: [String] = []
        if language != "en" {
            terms = await wikidataLabels(term, language: language)
        }
        terms.append(term)
        var unique: [String] = []
        for candidate in terms where !unique.contains(where: { normalized($0) == normalized(candidate) }) {
            unique.append(candidate)
        }
        let result = Array(unique.prefix(4))
        englishCache[key] = result
        return result
    }

    /// Wikidata's English labels for the best matches of the term in the user's language.
    private static func wikidataLabels(_ term: String, language: String) async -> [String] {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: term),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "uselang", value: "en"),
            URLQueryItem(name: "type", value: "item"),
            URLQueryItem(name: "limit", value: "4"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 6)
        // Wikimedia asks clients to identify themselves; nothing about the user is sent.
        request.setValue("JellyfinClient/1.0 (iOS; keyword search)", forHTTPHeaderField: "User-Agent")

        struct Response: Decodable {
            struct Entity: Decodable {
                struct Display: Decodable {
                    struct Label: Decodable { let value: String; let language: String }
                    let label: Label?
                }
                let display: Display?
            }
            let search: [Entity]
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        // Keywords are short ("time travel"); long labels are titles of books or films, not concepts.
        return decoded.search.compactMap { entity in
            guard let label = entity.display?.label, label.language == "en",
                  label.value.count <= 30, label.value.split(separator: " ").count <= 3 else { return nil }
            return label.value
        }
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
