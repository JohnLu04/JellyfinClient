import SwiftUI

/// Search tab (the separate magnifying glass at the bottom right): finds movies and series in your
/// libraries and, when Seerr is connected, suggests matching titles you don't have yet to request.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(SeerrStore.self) private var seerr

    @State private var query = ""
    @State private var library: [BaseItem] = []
    @State private var suggestions: [DiscoverItem] = []
    @State private var isSearching = false
    @State private var libraryError: String?
    @State private var seerrError: String?
    @State private var searchedTerm = ""
    @State private var selectedSuggestion: DiscoverItem?
    /// Titles on the searched topic ("Dinosaurier" → Jurassic Park), found by TMDB keyword.
    @State private var keywordResult: KeywordSearch.Result?

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if trimmed.isEmpty {
                    prompt
                        .containerRelativeFrame(.vertical)
                } else {
                    results
                }
            }
            .navigationTitle("Search")
            .appTopActions()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies & Series")
            #if DEBUG
            // Debug builds only: prefill from the launch environment (JF_DEBUG_SEARCH) for automated testing.
            .onAppear {
                if query.isEmpty, let term = ProcessInfo.processInfo.environment["JF_DEBUG_SEARCH"] { query = term }
            }
            #endif
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(350))    // debounce typing
                guard !Task.isCancelled else { return }
                await search()
            }
            // The topic search takes longer (Wikidata, then Seerr); its section joins when it's ready.
            .task(id: query) {
                keywordResult = nil
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, !trimmed.isEmpty else { return }
                let found = await KeywordSearch.search(trimmed, api: app.api, client: seerr.client)
                guard !Task.isCancelled else { return }
                withAnimation { keywordResult = found }
            }
            .itemNavigationDestinations()
            .navigationDestination(item: $selectedSuggestion) { item in
                SeerrTitleDetailView(item: item)
            }
        }
    }

    // MARK: - Content

    private var prompt: some View {
        ContentUnavailableView {
            Label("Search Movies & Series", systemImage: "magnifyingglass")
        } description: {
            Text(seerr.isConnected
                 ? "Finds titles in your libraries and suggests others from Seerr that you can request."
                 : "Finds titles in your libraries. Connect Seerr in Settings to also find titles you don't have yet.")
        }
    }

    @ViewBuilder
    private var results: some View {
        let isStale = searchedTerm != trimmed
        VStack(alignment: .leading, spacing: 28) {
            if isSearching && library.isEmpty && suggestions.isEmpty || isStale && library.isEmpty && suggestions.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else {
                librarySection
                seerrSection
                keywordSection
                if library.isEmpty && suggestions.isEmpty && libraryError == nil && seerrError == nil && keywordExtras.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                        .padding(.top, 40)
                }
            }
        }
        .padding(.vertical)
    }

    @ViewBuilder
    private var librarySection: some View {
        if !library.isEmpty || libraryError != nil {
            VStack(alignment: .leading, spacing: 12) {
                header("In Your Library")
                if let libraryError {
                    errorLabel(libraryError)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12, alignment: .top)], spacing: 16) {
                    ForEach(library) { item in
                        NavigationLink(value: item) { PosterCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var seerrSection: some View {
        if seerr.isConnected {
            if !suggestions.isEmpty || seerrError != nil {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        header("Request with Seerr")
                        Text("Not in your library yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    if let seerrError {
                        errorLabel(seerrError)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12, alignment: .top)], spacing: 18) {
                        ForEach(suggestions) { item in
                            Button { selectedSuggestion = item } label: {
                                SeerrPosterCard(url: item.posterURL, title: item.title, kind: item.mediaType.kind,
                                                chip: item.mediaType.label, footnote: item.year, badge: item.state)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        } else if !library.isEmpty || searchedTerm == trimmed {
            Label("Connect Seerr in Settings to also find movies and series you don't have yet.",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    private enum KeywordHit: Identifiable {
        case library(BaseItem)
        case seerr(DiscoverItem)
        var id: String {
            switch self {
            case .library(let item): "library-\(item.id)"
            case .seerr(let item): "seerr-\(item.id)"
            }
        }
    }

    /// Topic hits not already shown above (library copies first, then titles to request).
    private var keywordExtras: [KeywordHit] {
        guard let keywordResult, keywordResult.term == trimmed else { return [] }
        let shownLibrary = Set(library.map(\.id))
        let shownSeerr = Set(suggestions.map(\.id))
        return keywordResult.library.filter { !shownLibrary.contains($0.id) }.map(KeywordHit.library)
            + keywordResult.requestable.filter { !shownSeerr.contains($0.id) }.map(KeywordHit.seerr)
    }

    @ViewBuilder
    private var keywordSection: some View {
        let hits = keywordExtras
        if let keywordResult, !hits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matching “\(keywordResult.term)”")
                        .font(.title2.bold())
                    let names = keywordResult.keywords.joined(separator: ", ")
                    Text(keywordResult.keywords.count == 1 ? String(localized: "Keyword: \(names)") : String(localized: "Keywords: \(names)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(hits) { hit in
                        switch hit {
                        case .library(let item):
                            NavigationLink(value: item) { PosterCard(item: item) }
                                .buttonStyle(.plain)
                        case .seerr(let item):
                            Button { selectedSuggestion = item } label: {
                                SeerrPosterCard(url: item.posterURL, title: item.title, kind: item.mediaType.kind,
                                                chip: item.mediaType.label, footnote: item.year, badge: item.state)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .transition(.opacity)
        }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title2.bold())
            .padding(.horizontal)
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal)
    }

    // MARK: - Searching

    private func search() async {
        let term = trimmed
        guard !term.isEmpty else {
            library = []
            suggestions = []
            searchedTerm = ""
            return
        }
        isSearching = true
        defer { isSearching = false }

        async let libraryResult = searchLibrary(term)
        async let seerrResult = searchSeerr(term)
        let (libraryOutcome, seerrOutcome) = await (libraryResult, seerrResult)
        guard !Task.isCancelled else { return }

        switch libraryOutcome {
        case .success(let items): library = items; libraryError = nil
        case .failure(let error): library = []; libraryError = error.localizedDescription
        }
        switch seerrOutcome {
        case .success(let items): suggestions = Self.missing(items, from: library); seerrError = nil
        case .failure(let error): suggestions = []; seerrError = error.localizedDescription
        case nil: suggestions = []; seerrError = nil
        }
        searchedTerm = term
    }

    private func searchLibrary(_ term: String) async -> Result<[BaseItem], Error> {
        guard let api = app.api else { return .success([]) }
        do { return .success(try await api.searchItems(term)) } catch { return .failure(error) }
    }

    private func searchSeerr(_ term: String) async -> Result<[DiscoverItem], Error>? {
        guard let client = seerr.client else { return nil }
        do { return .success(try await client.search(term)) } catch { return .failure(error) }
    }

    /// Seerr results that aren't in the library: drops what Seerr marks as available and anything
    /// whose TMDB id (or title + year) matches a library item.
    private static func missing(_ results: [DiscoverItem], from library: [BaseItem]) -> [DiscoverItem] {
        let libraryTMDB = Set(library.compactMap { $0.providerID("Tmdb") })
        func normalized(_ text: String) -> String {
            text.lowercased().folding(options: [.diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
        }
        let libraryTitles = Set(library.map { item -> String in
            let type = item.type == "Series" ? "tv" : "movie"
            return "\(type)-\(normalized(item.name ?? ""))-\(item.productionYear.map(String.init) ?? "")"
        })
        return results.filter { result in
            if result.state == .available || result.state == .partiallyAvailable { return false }
            if libraryTMDB.contains(String(result.tmdbID)) { return false }
            let key = "\(result.mediaType.rawValue)-\(normalized(result.title))-\(result.year ?? "")"
            return !libraryTitles.contains(key)
        }
    }
}
