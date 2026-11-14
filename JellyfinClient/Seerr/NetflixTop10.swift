import Foundation

/// One title in Netflix's weekly Top 10.
struct Top10Entry: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(isSeries ? "tv" : "movie")-\(rank)" }
    let rank: Int
    /// As Netflix shows it, e.g. "Lupin: Part 4".
    let title: String
    /// The movie or show name used to find it in Seerr, e.g. "Lupin".
    let searchTitle: String
    /// "Part 4", "Season 3", "Limited Series" – nil for movies.
    let seasonLabel: String?
    let year: Int?
    let isSeries: Bool
}

struct Top10List: Codable, Sendable {
    /// "Germany", or "Global" when the country list couldn't be read.
    let region: String
    /// Last day (Sunday) of the ranked week.
    let weekEnd: Date
    let movies: [Top10Entry]
    let series: [Top10Entry]
    let fetchedAt: Date

    var weekStart: Date { weekEnd.addingTimeInterval(-6 * 86_400) }
}

/// Netflix's official weekly Top 10 (published every Tuesday for Monday–Sunday).
///
/// Country lists only exist on Netflix's Top 10 web pages, which embed their data as JSON;
/// the global list comes from the official data file. If a country page can't be read,
/// the global list is used instead so the section is never empty.
enum NetflixTop10 {
    static let countrySlug = "germany"
    static let countryName = "Germany"

    private static let base = "https://www.netflix.com/tudum/top10"
    private static let cacheMaxAge: TimeInterval = 6 * 3600

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("netflix-top10.json")
    }

    /// Cached list if it's fresh, otherwise a new one (falling back to an older cache when offline).
    /// Seasons of the same show are merged, so every series appears once.
    static func load(forceRefresh: Bool = false) async throws -> Top10List {
        let list = try await loadRaw(forceRefresh: forceRefresh)
        return Top10List(region: list.region, weekEnd: list.weekEnd, movies: list.movies,
                         series: mergeSeasons(list.series), fetchedAt: list.fetchedAt)
    }

    private static func loadRaw(forceRefresh: Bool) async throws -> Top10List {
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? decoder.decode(Top10List.self, from: $0) }
        if !forceRefresh, let cached, Date.now.timeIntervalSince(cached.fetchedAt) < cacheMaxAge {
            return cached
        }
        do {
            let list = try await fetch()
            if let data = try? encoder.encode(list) { try? data.write(to: cacheURL, options: .atomic) }
            return list
        } catch {
            if let cached { return cached }
            throw error
        }
    }

    private static func fetch() async throws -> Top10List {
        async let moviesPage = try? text(from: "\(base)/\(countrySlug)")
        async let seriesPage = try? text(from: "\(base)/\(countrySlug)/tv")
        let (moviesHTML, seriesHTML) = await (moviesPage, seriesPage)
        if let moviesHTML, let seriesHTML,
           let movies = parseCountryPage(moviesHTML, series: false),
           let series = parseCountryPage(seriesHTML, series: true) {
            return Top10List(region: countryName, weekEnd: max(movies.weekEnd, series.weekEnd),
                             movies: movies.entries, series: series.entries, fetchedAt: .now)
        }
        let tsv = try await text(from: "\(base)/data/all-weeks-global.tsv")
        guard let global = parseGlobalTSV(tsv) else { throw SeerrError.badResponse }
        return global
    }

    private static func text(from url: String) async throws -> String {
        guard let url = URL(string: url) else { throw SeerrError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw SeerrError.badResponse
        }
        return text
    }

    // MARK: Country page

    /// The page sets `netflix.reactContext.models.graphql = JSON.parse('…')`; its `data` map holds
    /// `PulseTop10ItemEntity:*` objects with rank, week and title.
    static func parseCountryPage(_ html: String, series: Bool) -> (weekEnd: Date, entries: [Top10Entry])? {
        let marker = "netflix.reactContext.models.graphql = JSON.parse('"
        guard let start = html.range(of: marker)?.upperBound,
              let json = unescapeJSString(html[start...]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let data = root["data"] as? [String: Any] else { return nil }

        var byVideo: [Int: Top10Entry] = [:]
        var weekEnds: [String] = []
        for (key, value) in data where key.hasPrefix("PulseTop10ItemEntity:") {
            guard let entity = value as? [String: Any],
                  let top10 = entity["top10"] as? [String: Any],
                  let video = entity["top10Video"] as? [String: Any],
                  let rank = top10["weeklyRank"] as? Int,
                  let videoID = top10["videoId"] as? Int,
                  let title = video["title"] as? String else { continue }
            let category = (top10["category"] as? String)?.uppercased() ?? ""
            guard series ? category.contains("SERIES") || category.contains("TV") : category.contains("MOVIE") else { continue }
            if let week = top10["weekEndDate"] as? String { weekEnds.append(week) }
            let show = (video["parentShow"] as? [String: Any])?["title"] as? String
            byVideo[videoID] = Top10Entry(rank: rank, title: title, searchTitle: show ?? title,
                                          seasonLabel: series ? seasonLabel(title: title, show: show) : nil,
                                          year: video["releaseYear"] as? Int, isSeries: series)
        }
        // A page can hold the same list twice (cards and table) – keyed by video, then one per rank.
        var byRank: [Int: Top10Entry] = [:]
        for entry in byVideo.values where byRank[entry.rank] == nil { byRank[entry.rank] = entry }
        let entries = byRank.values.sorted { $0.rank < $1.rank }.prefix(10)
        guard entries.count >= 5, let week = weekEnds.max(), let weekEnd = day(week) else { return nil }
        return (weekEnd, Array(entries))
    }

    /// Reads a JavaScript single-quoted string literal up to its closing quote.
    static func unescapeJSString(_ text: Substring) -> String {
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar {
            case "'":
                return String(result)
            case "\\":
                guard let next = scalars.next() else { return String(result) }
                switch next {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "u", "x":
                    var hex = ""
                    for _ in 0..<(next == "u" ? 4 : 2) { if let h = scalars.next() { hex.unicodeScalars.append(h) } }
                    if let value = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(value) { result.append(decoded) }
                default: result.append(next)
                }
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: Global file

    /// `week, category, weekly_rank, show_title, season_title, weekly_hours_viewed, runtime, weekly_views, …`
    /// Netflix ranks English and non-English titles separately; both are merged by views for one list.
    static func parseGlobalTSV(_ tsv: String) -> Top10List? {
        struct Row { let category: String; let show: String; let season: String?; let views: Double; let rank: Int }
        var rows: [String: [Row]] = [:]
        for line in tsv.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 8, let rank = Int(columns[2]) else { continue }
            let season = columns[4] == "N/A" || columns[4].isEmpty ? nil : columns[4]
            let views = Double(columns[7]) ?? Double(columns[5]) ?? 0
            rows[columns[0], default: []].append(Row(category: columns[1], show: columns[3], season: season, views: views, rank: rank))
        }
        guard let week = rows.keys.max(), let weekRows = rows[week], let weekEnd = day(week) else { return nil }

        func top(_ prefix: String, series: Bool) -> [Top10Entry] {
            weekRows.filter { $0.category.hasPrefix(prefix) }
                .sorted { $0.views != $1.views ? $0.views > $1.views : $0.rank < $1.rank }
                .prefix(10).enumerated()
                .map { index, row in
                    Top10Entry(rank: index + 1, title: row.season ?? row.show, searchTitle: row.show,
                               seasonLabel: series ? seasonLabel(title: row.season ?? row.show, show: row.show) : nil,
                               year: nil, isSeries: series)
                }
        }
        let movies = top("Films", series: false)
        let series = top("TV", series: true)
        guard !movies.isEmpty || !series.isEmpty else { return nil }
        return Top10List(region: "Global", weekEnd: weekEnd, movies: movies, series: series, fetchedAt: .now)
    }

    // MARK: One entry per show

    /// "Lupin: Part 4" (#1), "Lupin: Part 1" (#2) … become one "Lupin" at its best rank with "Parts 1–4";
    /// the remaining shows move up so ranks stay consecutive.
    static func mergeSeasons(_ entries: [Top10Entry]) -> [Top10Entry] {
        var order: [String] = []
        var groups: [String: [Top10Entry]] = [:]
        for entry in entries.sorted(by: { $0.rank < $1.rank }) {
            let key = entry.searchTitle.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.enumerated().compactMap { index, key in
            guard let group = groups[key], let best = group.first else { return nil }
            guard group.count > 1 else {
                return Top10Entry(rank: index + 1, title: best.title, searchTitle: best.searchTitle,
                                  seasonLabel: best.seasonLabel, year: best.year, isSeries: best.isSeries)
            }
            return Top10Entry(rank: index + 1, title: best.searchTitle, searchTitle: best.searchTitle,
                              seasonLabel: combinedLabel(group.compactMap(\.seasonLabel)),
                              year: group.compactMap(\.year).min(), isSeries: best.isSeries)
        }
    }

    /// ["Part 4", "Part 1", "Part 3", "Part 2"] → "Parts 1–4"; ["Season 1", "Season 3"] → "Seasons 1, 3".
    static func combinedLabel(_ labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        let parsed = labels.map { label -> (word: String, number: Int)? in
            let parts = label.split(separator: " ")
            guard parts.count == 2, let number = Int(parts[1]) else { return nil }
            return (String(parts[0]), number)
        }
        let words = Set(parsed.compactMap { $0?.word })
        guard parsed.allSatisfy({ $0 != nil }), words.count == 1, let word = words.first else {
            return "\(labels.count) seasons"
        }
        let numbers = Set(parsed.compactMap { $0?.number }).sorted()
        let isRange = numbers.count > 2 && numbers.last! - numbers.first! == numbers.count - 1
        let list = isRange ? "\(numbers.first!)–\(numbers.last!)" : numbers.map(String.init).joined(separator: ", ")
        return "\(word)s \(list)"
    }

    // MARK: Helpers

    /// "Lupin: Part 4" with show "Lupin" → "Part 4".
    private static func seasonLabel(title: String, show: String?) -> String? {
        guard let show, title.hasPrefix(show + ":") else { return nil }
        let label = title.dropFirst(show.count + 1).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    private static func day(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
