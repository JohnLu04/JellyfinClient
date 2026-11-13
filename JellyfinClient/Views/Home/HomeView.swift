import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    @State private var path = NavigationPath()
    @State private var hero: [HeroEntry] = []
    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var latestRows: [(library: BaseItem, items: [BaseItem])] = []
    @State private var libraries: [BaseItem] = []
    @State private var favorites: Set<String> = []
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var playError: String?

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        if !hero.isEmpty {
                            HeroCarousel(title: "Home", entries: hero, topInset: geo.safeAreaInsets.top,
                                         favorites: favorites,
                                         onOpen: { path.append($0) },
                                         onPlay: play,
                                         onToggleFavorite: toggleFavorite)
                        } else {
                            Text("Home")
                                .font(.largeTitle.bold())
                                .padding(.horizontal)
                                .padding(.top, geo.safeAreaInsets.top + 8)
                        }

                        if !resume.isEmpty {
                            row("Continue Watching", subtitle: "Your started movies and series") {
                                ForEach(resume) { item in
                                    Button { path.append(destination(for: item)) } label: { ContinueWatchingCard(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }

                        if !nextUp.isEmpty {
                            row("Next Up", subtitle: "The next episodes of your series") {
                                ForEach(nextUp) { item in
                                    Button { path.append(destination(for: item)) } label: { ContinueWatchingCard(item: item, width: 240) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }

                        ForEach(latestRows, id: \.library.id) { row in
                            self.row("Recently Added in \(row.library.name ?? "")") {
                                ForEach(row.items) { item in
                                    NavigationLink(value: item) { PosterCard(item: item).frame(width: 118) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }

                        if !libraries.isEmpty {
                            row("Libraries") {
                                ForEach(libraries) { library in
                                    NavigationLink(value: library) { LibraryTile(item: library).frame(width: 230) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .ignoresSafeArea(edges: .top)
                .overlay {
                    if !hasLoaded {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage, libraries.isEmpty {
                        ContentUnavailableView {
                            Label("Can't reach the server", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Try Again") { Task { await load() } }
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .itemNavigationDestinations()
            .refreshable { await load() }
            .task { if !hasLoaded { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
                Task { await load() }
            }
            .alert("Playback failed", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playError ?? "")
            }
        }
    }

    // MARK: - Rows

    private func row<Content: View>(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal)
            }
        }
    }

    /// Episodes open their series page (whose play button resumes them), movies their own page.
    private func destination(for item: BaseItem) -> BaseItem {
        guard item.type == "Episode", let seriesId = item.seriesId else { return item }
        return hero.first { $0.display.id == seriesId }?.display ?? seriesStub(for: item, id: seriesId)
    }

    // MARK: - Actions

    private func play(_ entry: HeroEntry) {
        guard let api = app.api else { return }
        Task {
            do {
                var target = entry.target
                if target == nil, entry.display.type == "Series" {
                    target = try await api.episodeToPlay(seriesId: entry.display.id)
                }
                guard let target else { return path.append(entry.display) }
                try await PlaybackCoordinator.shared.playWithDefaults(target, api: api)
            } catch {
                playError = error.localizedDescription
            }
        }
    }

    private func toggleFavorite(_ item: BaseItem) {
        guard let api = app.api else { return }
        let newValue = !favorites.contains(item.id)
        if newValue { favorites.insert(item.id) } else { favorites.remove(item.id) }
        Task {
            do {
                try await api.setFavorite(itemId: item.id, newValue)
            } catch {
                if newValue { favorites.remove(item.id) } else { favorites.insert(item.id) }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let api = app.api else { return }
        do {
            async let viewsRequest = api.userViews()
            async let resumeRequest = api.resumeItems()
            async let nextUpRequest = api.nextUp(limit: 12, includeResumable: false)

            let views = try await viewsRequest.filter(\.isSupportedLibrary)
            let resumeItems = (try? await resumeRequest) ?? []
            let nextUpItems = (try? await nextUpRequest) ?? []

            let rows = await latestRows(for: views, api: api)
            let heroEntries = await buildHero(resume: resumeItems, nextUp: nextUpItems, latest: rows, api: api)

            libraries = views
            resume = resumeItems
            nextUp = nextUpItems
            latestRows = rows
            hero = heroEntries
            favorites = Set(heroEntries.map(\.display).filter(\.isFavorite).map(\.id))
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            await app.handle(error)
        }
        hasLoaded = true
    }

    private func latestRows(for views: [BaseItem], api: JellyfinAPI) async -> [(library: BaseItem, items: [BaseItem])] {
        let candidates = views.filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }
        return await withTaskGroup(of: (Int, BaseItem, [BaseItem]).self) { group in
            for (index, library) in candidates.enumerated() {
                group.addTask { (index, library, (try? await api.latest(parentId: library.id)) ?? []) }
            }
            var results: [(Int, BaseItem, [BaseItem])] = []
            for await result in group where !result.2.isEmpty { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { (library: $0.1, items: $0.2) }
        }
    }

    /// Hero: what you're watching first (shown as its series), then new additions; up to 6 titles.
    private func buildHero(resume: [BaseItem], nextUp: [BaseItem], latest: [(library: BaseItem, items: [BaseItem])],
                           api: JellyfinAPI) async -> [HeroEntry] {
        var seen = Set<String>()
        var picks: [(display: String, target: BaseItem?, item: BaseItem)] = []
        func add(_ item: BaseItem, target: BaseItem?) {
            let displayId = item.type == "Episode" ? (item.seriesId ?? item.id) : item.id
            guard picks.count < 6, seen.insert(displayId).inserted else { return }
            picks.append((displayId, target, item))
        }
        resume.prefix(3).forEach { add($0, target: $0) }
        nextUp.prefix(2).forEach { add($0, target: $0) }
        for row in latest { row.items.prefix(2).forEach { add($0, target: $0.type == "Movie" ? $0 : nil) } }

        // Episodes are shown as their series: fetch those for artwork, logo and genres.
        return await withTaskGroup(of: (Int, HeroEntry).self) { group in
            for (index, pick) in picks.enumerated() {
                group.addTask {
                    if pick.item.type == "Episode", let series = try? await api.item(id: pick.display) {
                        return (index, HeroEntry(display: series, target: pick.target))
                    }
                    if pick.item.type == "Series" || pick.item.type == "Movie",
                       let full = try? await api.item(id: pick.item.id) {
                        return (index, HeroEntry(display: full, target: pick.target.map { _ in full }))
                    }
                    return (index, HeroEntry(display: pick.item, target: pick.target))
                }
            }
            var entries: [(Int, HeroEntry)] = []
            for await entry in group { entries.append(entry) }
            return entries.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Minimal series item for navigation when the series wasn't fetched for the hero.
    private func seriesStub(for episode: BaseItem, id: String) -> BaseItem {
        let json: [String: Any] = ["Id": id, "Name": episode.seriesName ?? "", "Type": "Series", "IsFolder": true]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (try? JSONCoding.decoder.decode(BaseItem.self, from: data)) ?? episode
    }
}
