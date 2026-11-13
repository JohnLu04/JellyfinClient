import SwiftUI

struct LibraryItemsView: View {
    @Environment(AppModel.self) private var app
    let parent: BaseItem

    @State private var items: [BaseItem] = []
    @State private var totalCount: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let pageSize = 60

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.id == items.last?.id { Task { await loadMore() } }
                        }
                }
            }
            .padding()

            if isLoading && !items.isEmpty {
                ProgressView().padding()
            }
        }
        .overlay {
            if items.isEmpty {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load items", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { Task { await loadMore() } }
                    }
                } else if totalCount == 0 {
                    ContentUnavailableView("Nothing here yet", systemImage: "film")
                }
            }
        }
        .navigationTitle(parent.name ?? String(localized: "Library"))
        .task { if items.isEmpty { await loadMore() } }
        .refreshable {
            items = []
            totalCount = nil
            await loadMore()
        }
    }

    private var hasMore: Bool { totalCount.map { items.count < $0 } ?? true }

    private func loadMore() async {
        guard !isLoading, hasMore, let api = app.api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.items(in: parent, startIndex: items.count, limit: pageSize)
            items += page.items
            totalCount = page.items.count < pageSize ? items.count : (page.totalRecordCount ?? items.count + 1)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            await app.handle(error)
        }
    }
}
