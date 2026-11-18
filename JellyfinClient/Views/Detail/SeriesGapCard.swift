import SwiftUI

/// What a series in the library is missing compared to what has aired, according to Seerr (TMDB).
struct SeriesGap: Equatable {
    struct Incomplete: Equatable {
        let season: Int
        let missingEpisodes: Int
    }

    /// Aired seasons with no episode on the server, not requested yet.
    var missingSeasons: [Int] = []
    /// Seasons on the server that lack aired episodes, not requested yet.
    var incompleteSeasons: [Incomplete] = []
    /// Missing or incomplete seasons that are already requested (waiting for approval or downloading).
    var requestedSeasons: [Int] = []

    var canRequest: Bool { !missingSeasons.isEmpty || !incompleteSeasons.isEmpty }
    var isEmpty: Bool { !canRequest && requestedSeasons.isEmpty }
}

enum SeriesGapChecker {
    /// Compares the episodes on the server with the seasons and episodes TMDB lists as aired.
    /// Returns nil without Seerr, without a TMDB id, or when nothing is missing.
    static func check(series: BaseItem, api: JellyfinAPI, client: SeerrClient) async -> (gap: SeriesGap, item: DiscoverItem)? {
        guard let tmdb = series.providerID("Tmdb").flatMap(Int.init) else { return nil }
        async let detailsRequest = client.details(.tv, tmdbID: tmdb)
        async let ownedRequest = api.ownedEpisodes(seriesId: series.id)
        guard let details = try? await detailsRequest, let owned = try? await ownedRequest else { return nil }

        // Episode numbers on the server per season (a file with E01-E02 counts for both).
        var have: [Int: Set<Int>] = [:]
        var unnumbered: [Int: Int] = [:]
        for episode in owned {
            guard let season = episode.parentIndexNumber else { continue }
            if let number = episode.indexNumber {
                have[season, default: []].formUnion(number...max(number, episode.indexNumberEnd ?? number))
            } else {
                unnumbered[season, default: 0] += 1
            }
        }

        let now = Date()
        var gap = SeriesGap()
        for season in details.seasons where season.number > 0 {
            guard let aired = season.airDate, aired <= now else { continue }   // not out yet
            let numbers = have[season.number] ?? []
            let count = numbers.count + (unnumbered[season.number] ?? 0)
            let isRequested = season.state == .pendingApproval || season.state == .processing
            if count == 0 {
                // Seerr sees it on the server: Jellyfin probably numbers it differently, so don't call it missing.
                if season.state == .available || season.state == .partiallyAvailable { continue }
                if isRequested { gap.requestedSeasons.append(season.number) } else { gap.missingSeasons.append(season.number) }
            } else if season.episodeCount > count {
                // TMDB's count includes episodes still to come: only aired ones count as missing.
                guard let episodes = try? await client.episodes(tmdbID: tmdb, season: season.number) else { continue }
                let airedNumbers = Set(episodes.filter { ($0.airDate ?? .distantFuture) <= now }.map(\.number))
                let missing = airedNumbers.subtracting(numbers).count - (unnumbered[season.number] ?? 0)
                guard missing > 0 else { continue }
                if isRequested {
                    gap.requestedSeasons.append(season.number)
                } else {
                    gap.incompleteSeasons.append(.init(season: season.number, missingEpisodes: missing))
                }
            }
        }
        guard !gap.isEmpty else { return nil }
        let item = DiscoverItem(tmdbID: tmdb, mediaType: .tv, title: details.title, year: details.year,
                                posterURL: details.posterURL, overview: details.overview, state: details.state)
        return (gap, item)
    }
}

/// On a series page: which aired seasons or episodes aren't on the server yet, with a button to
/// request them in Seerr.
struct SeriesGapCard: View {
    let gap: SeriesGap
    let onRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: gap.canRequest ? "rectangle.stack.badge.plus" : "clock.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if gap.canRequest {
                Button(action: onRequest) {
                    Label("Request More", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch (gap.missingSeasons.isEmpty, gap.incompleteSeasons.isEmpty) {
        case (false, false): String(localized: "More Episodes Available")
        case (false, true): String(localized: "More Seasons Available")
        case (true, false):
            gap.incompleteSeasons.count == 1 ? String(localized: "Season Incomplete") : String(localized: "Seasons Incomplete")
        case (true, true): String(localized: "More Seasons Requested")
        }
    }

    private var lines: [String] {
        var lines: [String] = []
        if !gap.missingSeasons.isEmpty {
            let list = Self.list(gap.missingSeasons)
            lines.append(gap.missingSeasons.count == 1 ? String(localized: "Season \(list) isn't in your library yet.")
                                                       : String(localized: "Seasons \(list) aren't in your library yet."))
        }
        for season in gap.incompleteSeasons {
            lines.append(season.missingEpisodes == 1 ? String(localized: "Season \(season.season): 1 episode missing.")
                                                     : String(localized: "Season \(season.season): \(season.missingEpisodes) episodes missing."))
        }
        if !gap.requestedSeasons.isEmpty {
            let list = Self.list(gap.requestedSeasons)
            lines.append(gap.requestedSeasons.count == 1 ? String(localized: "Season \(list) is requested.")
                                                         : String(localized: "Seasons \(list) are requested."))
        }
        return lines
    }

    /// "2", "2 and 3", "2, 3 and 4" in the device's language.
    private static func list(_ numbers: [Int]) -> String {
        numbers.map(String.init).formatted(.list(type: .and))
    }
}
