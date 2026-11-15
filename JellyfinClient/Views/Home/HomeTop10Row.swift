import SwiftUI

/// Netflix's Top 10 movies or series of the week on the Home screen (the same list as in Request).
/// Titles that are in the library show their Jellyfin poster with a green dot and open their page;
/// the others open Seerr to request them when it's connected.
struct HomeTop10Row: View {
    @Environment(SeerrStore.self) private var seerr

    let list: Top10List
    let isSeries: Bool
    let api: JellyfinAPI?
    let onOpenItem: (BaseItem) -> Void
    let onOpenSeerr: (DiscoverItem) -> Void

    @State private var libraryMatches: [String: BaseItem] = [:]
    @State private var seerrMatches: [String: DiscoverItem] = [:]

    private var entries: [Top10Entry] { isSeries ? list.series : list.movies }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isSeries ? "Top 10 Series on Netflix" : "Top 10 Movies on Netflix")
                        .font(.title2.bold())
                    Text("\(regionName) · \(list.weekStart.formatted(.dateTime.day().month(.abbreviated))) – \(list.weekEnd.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 14) {
                        ForEach(entries) { entry in
                            card(for: entry)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
            .task(id: "\(list.fetchedAt.timeIntervalSince1970)-\(seerr.isConnected)") { await match() }
        }
    }

    @ViewBuilder
    private func card(for entry: Top10Entry) -> some View {
        let key = NetflixTop10.matchKey(entry)
        if let item = libraryMatches[key] {
            Button { onOpenItem(item) } label: {
                Top10Card(entry: entry, posterURL: api?.posterURL(for: item, maxWidth: 300) ?? seerrMatches[key]?.posterURL,
                          badge: .available)
            }
            .buttonStyle(.plain)
        } else {
            let request = seerrMatches[key]
            Button { if let request { onOpenSeerr(request) } } label: {
                Top10Card(entry: entry, item: request)
            }
            .buttonStyle(.plain)
            .disabled(request == nil)
        }
    }

    private var regionName: String {
        list.region == NetflixTop10.countryName ? String(localized: "Netflix Germany") : String(localized: "Netflix worldwide")
    }

    // MARK: - Matching

    private func match() async {
        async let library = matchLibrary()
        async let requests = matchSeerr()
        let (foundLibrary, foundRequests) = await (library, requests)
        libraryMatches = foundLibrary
        seerrMatches = foundRequests
    }

    private func matchSeerr() async -> [String: DiscoverItem] {
        guard let service = seerr.client else { return [:] }
        return await NetflixTop10.seerrMatches(for: entries, service: service)
    }

    /// Searches the library for each title: same type, same title (ignoring case, accents and
    /// punctuation), for movies also a year within one.
    private func matchLibrary() async -> [String: BaseItem] {
        guard let api else { return [:] }
        var unique: [String: Top10Entry] = [:]
        for entry in entries where unique[NetflixTop10.matchKey(entry)] == nil { unique[NetflixTop10.matchKey(entry)] = entry }
        var found: [String: BaseItem] = [:]
        await withTaskGroup(of: (String, BaseItem?).self) { group in
            for (key, entry) in unique {
                group.addTask {
                    let results = (try? await api.searchItems(entry.searchTitle, limit: 20)) ?? []
                    return (key, Self.libraryMatch(for: entry, in: results))
                }
            }
            for await (key, item) in group {
                if let item { found[key] = item }
            }
        }
        return found
    }

    nonisolated private static func libraryMatch(for entry: Top10Entry, in results: [BaseItem]) -> BaseItem? {
        let type = entry.isSeries ? "Series" : "Movie"
        let wanted = NetflixTop10.normalizedTitle(entry.searchTitle)
        let candidates = results.filter {
            $0.type == type && ([$0.name, $0.originalTitle].compactMap { $0 }.contains { NetflixTop10.normalizedTitle($0) == wanted })
        }
        guard !entry.isSeries, let year = entry.year else { return candidates.first }
        return candidates.first { item in item.productionYear.map { abs($0 - year) <= 1 } ?? true }
    }
}
