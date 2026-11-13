import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var libraries: [BaseItem] = []
    @State private var resume: [BaseItem] = []
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !resume.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("Continue Watching")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(resume) { item in
                                        NavigationLink(value: item) { ContinueWatchingCard(item: item) }
                                            .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    if !libraries.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("Libraries")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                                ForEach(libraries) { library in
                                    NavigationLink(value: library) { LibraryTile(item: library) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .overlay {
                if !hasLoaded {
                    ProgressView()
                } else if let errorMessage, libraries.isEmpty {
                    ContentUnavailableView {
                        Label("Can't reach the server", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if libraries.isEmpty {
                    ContentUnavailableView("No video libraries", systemImage: "film.stack")
                }
            }
            .navigationTitle("Home")
            .itemNavigationDestinations()
            .refreshable { await load() }
            .task { if !hasLoaded { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
                Task { await load() }
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title2.bold())
            .padding(.horizontal)
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            async let views = api.userViews()
            async let resumeItems = api.resumeItems()
            libraries = try await views.filter(\.isSupportedLibrary)
            resume = (try? await resumeItems) ?? []
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
