import SwiftUI

/// Adds or removes favorites and keeps every screen in sync.
enum Favorites {
    /// Updates the server and notifies all screens right away (optimistically). If the server refuses,
    /// the change is announced back and `false` is returned.
    @MainActor @discardableResult
    static func set(_ itemId: String, favorite: Bool, api: JellyfinAPI) async -> Bool {
        announce(itemId, favorite)
        do {
            _ = try await api.setFavorite(itemId: itemId, favorite)
            return true
        } catch {
            announce(itemId, !favorite)
            return false
        }
    }

    @MainActor private static func announce(_ itemId: String, _ favorite: Bool) {
        NotificationCenter.default.post(name: .favoriteDidChange, object: itemId, userInfo: ["isFavorite": favorite])
    }
}

/// "Favorites" tab: favorite movies, series and episodes as poster grids.
struct FavoritesView: View {
    @Environment(AppModel.self) private var app

    @State private var items: [BaseItem] = []
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if items.isEmpty {
                    placeholder
                        .containerRelativeFrame(.vertical)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        section("Movies", items.filter { $0.type == "Movie" })
                        section("Series", items.filter { $0.type == "Series" })
                        section("Episodes", items.filter { $0.type == "Episode" })
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Favorites")
            .appTopActions()
            .itemNavigationDestinations()
            .refreshable { await load() }
            .onAppear { Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: .favoriteDidChange)) { note in
                // Removing shows immediately; additions need the full item, so fetch the list again.
                if let id = note.object as? String, note.userInfo?["isFavorite"] as? Bool == false {
                    withAnimation { items.removeAll { $0.id == id } }
                } else {
                    Task { await load() }
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if !hasLoaded {
            ProgressView().controlSize(.large)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't load favorites", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ContentUnavailableView("No Favorites Yet", systemImage: "heart",
                                   description: Text("Tap the heart on a movie or series to find it here."))
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ items: [BaseItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                    .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { PosterCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            items = try await api.favoriteItems()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            await app.handle(error)
        }
        hasLoaded = true
    }
}

/// "Library" tab: all of the server's libraries.
struct LibraryView: View {
    @Environment(AppModel.self) private var app

    @State private var libraries: [BaseItem] = []
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if libraries.isEmpty {
                    placeholder
                        .containerRelativeFrame(.vertical)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(libraries) { library in
                            NavigationLink(value: library) { LibraryTile(item: library) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Library")
            .appTopActions()
            .itemNavigationDestinations()
            .refreshable { await load() }
            .task { if !hasLoaded { await load() } }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if !hasLoaded {
            ProgressView().controlSize(.large)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Can't reach the server", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ContentUnavailableView("Nothing here yet", systemImage: "rectangle.stack")
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            libraries = try await api.userViews().filter(\.isSupportedLibrary)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            await app.handle(error)
        }
        hasLoaded = true
    }
}

// MARK: - Top right buttons

/// Downloads and settings, top right on every tab. Both open as sheets.
struct AppTopActions: ViewModifier {
    /// For screens without a navigation bar (home): float the buttons over the content, next to the large title.
    var floating = false

    @Environment(DownloadManager.self) private var downloads
    @State private var showDownloads = false
    @State private var showSettings = false

    func body(content: Content) -> some View {
        Group {
            if floating {
                content.overlay(alignment: .topTrailing) {
                    HStack(spacing: 10) {
                        floatingButton(downloadsSymbol, label: "Downloads") { showDownloads = true }
                            .overlay(alignment: .topTrailing) { activityDot }
                        floatingButton("gearshape", label: "Settings") { showSettings = true }
                    }
                    .padding(.trailing)
                    .padding(.top, 6)        // the overlay already sits below the status bar
                }
            } else {
                content.toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showDownloads = true } label: {
                            Image(systemName: downloadsSymbol)
                                .overlay(alignment: .topTrailing) { activityDot.offset(x: 4, y: -4) }
                        }
                        .accessibilityLabel("Downloads")
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
            }
        }
        .sheet(isPresented: $showDownloads) { DownloadsView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var downloadsSymbol: String { "arrow.down.circle" }

    @ViewBuilder
    private var activityDot: some View {
        if downloads.hasActiveDownloads {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .allowsHitTesting(false)
        }
    }

    private func floatingButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .accessibilityLabel(label)
    }
}

extension View {
    /// Downloads and settings buttons top right. Use `floating` on screens without a navigation bar.
    func appTopActions(floating: Bool = false) -> some View {
        modifier(AppTopActions(floating: floating))
    }
}
