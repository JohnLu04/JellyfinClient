import SwiftUI

enum RequestFilter: String, CaseIterable, Identifiable {
    case all, pending, processing, available
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .pending: String(localized: "Pending")
        case .processing: String(localized: "Processing")
        case .available: String(localized: "Available")
        }
    }

    var emptyText: String {
        switch self {
        case .all: String(localized: "Nobody has requested anything yet.")
        case .pending: String(localized: "No pending requests.")
        case .processing: String(localized: "No requests being processed.")
        case .available: String(localized: "No available requests.")
        }
    }

    func matches(_ state: SeerrState) -> Bool {
        switch self {
        case .all: true
        case .pending: state == .pendingApproval
        case .processing: state == .processing
        case .available: state == .available || state == .partiallyAvailable
        }
    }
}

struct SeerrRequestsView: View {
    @Environment(SeerrStore.self) private var seerr

    @State private var items: [RequestItem] = []
    @State private var errors: [String] = []
    @State private var hasLoaded = false
    @State private var filter: RequestFilter = .all
    @State private var isSearching = false
    @State private var busyIDs: Set<Int> = []

    private var visibleItems: [RequestItem] { items.filter { filter.matches($0.state) } }

    /// Pushed from the Request tab, so it lives in its NavigationStack.
    var body: some View {
        Group {
            Group {
                if !seerr.isConnected {
                    SeerrNotConnectedView()
                } else {
                    List {
                        Picker("Filter", selection: $filter) {
                            ForEach(RequestFilter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())

                        if !errors.isEmpty {
                            Section {
                                ForEach(errors, id: \.self) { message in
                                    Label(message, systemImage: "exclamationmark.triangle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                }
                            }
                        }

                        ForEach(visibleItems) { item in
                            RequestRow(item: item, isBusy: busyIDs.contains(item.id))
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        Task { await perform(.delete, on: item) }
                                    }
                                    if item.state == .pendingApproval {
                                        Button("Decline", systemImage: "xmark") {
                                            Task { await perform(.decline, on: item) }
                                        }
                                        .tint(.orange)
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if item.state == .pendingApproval {
                                        Button("Approve", systemImage: "checkmark") {
                                            Task { await perform(.approve, on: item) }
                                        }
                                        .tint(.green)
                                    }
                                }
                                .contextMenu {
                                    if item.state == .pendingApproval {
                                        Button("Approve", systemImage: "checkmark") { Task { await perform(.approve, on: item) } }
                                        Button("Decline", systemImage: "xmark") { Task { await perform(.decline, on: item) } }
                                    }
                                    Button("Delete Request", systemImage: "trash", role: .destructive) {
                                        Task { await perform(.delete, on: item) }
                                    }
                                }
                        }
                    }
                    .overlay {
                        if !hasLoaded {
                            ProgressView()
                        } else if visibleItems.isEmpty && errors.isEmpty {
                            ContentUnavailableView("No Requests", systemImage: "tray",
                                                   description: Text(filter.emptyText))
                        }
                    }
                    .refreshable { await load() }
                    .task(id: seerr.config) { await load() }
                    .toolbar {
                        Button("Request", systemImage: "plus") { isSearching = true }
                    }
                    .sheet(isPresented: $isSearching, onDismiss: { Task { await load() } }) {
                        SeerrSearchView()
                    }
                }
            }
            .navigationTitle("Requests")
        }
        .themedBackground()
    }

    private enum Action { case approve, decline, delete }

    private func load() async {
        guard let client = seerr.client else { return }
        do {
            let loaded = try await client.requests()
            guard !Task.isCancelled else { return }
            items = loaded.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            errors = []
        } catch is CancellationError {
            return
        } catch {
            errors = [error.localizedDescription]
        }
        hasLoaded = true
    }

    private func perform(_ action: Action, on item: RequestItem) async {
        guard let client = seerr.client else { return }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        do {
            switch action {
            case .approve: try await client.approve(requestID: item.requestID)
            case .decline: try await client.decline(requestID: item.requestID)
            case .delete: try await client.delete(requestID: item.requestID)
            }
            await load()
        } catch {
            errors.append(error.localizedDescription)
        }
    }
}

private struct RequestRow: View {
    let item: RequestItem
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: item.posterURL, title: item.title, kind: item.mediaType.kind)
                .frame(width: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: item.mediaType.systemImage)
                    Text([item.year, seasonsText, item.is4k ? "4K" : nil].compactMap { $0 }.joined(separator: " · "))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(requestedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                StatusBadge(state: item.state)
            }
            Spacer(minLength: 0)
            if isBusy { ProgressView() }
        }
        .padding(.vertical, 2)
    }

    private var seasonsText: String? {
        guard item.mediaType == .tv, !item.seasons.isEmpty else { return nil }
        return item.seasons.count == 1 ? String(localized: "Season \(item.seasons[0])") : String(localized: "\(item.seasons.count) Seasons")
    }

    private var requestedText: String {
        guard let date = item.createdAt else { return String(localized: "Requested by \(item.requestedBy)") }
        return "\(item.requestedBy) · \(date.formatted(.relative(presentation: .named)))"
    }
}

/// Search TMDB through Seerr and create new requests.
struct SeerrSearchView: View {
    @Environment(SeerrStore.self) private var seerr
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [DiscoverItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var requested: Set<String> = []
    @State private var requesting: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                ForEach(results) { item in
                    HStack(spacing: 12) {
                        PosterImage(url: item.posterURL, title: item.title, kind: item.mediaType.kind)
                            .frame(width: 54)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline).lineLimit(2)
                            Label([item.mediaType.label, item.year].compactMap { $0 }.joined(separator: " · "),
                                  systemImage: item.mediaType.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let overview = item.overview, !overview.isEmpty {
                                Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        requestButton(for: item)
                    }
                }
            }
            .overlay {
                if isLoading && results.isEmpty {
                    ProgressView()
                } else if query.isEmpty && results.isEmpty {
                    ContentUnavailableView("Search Movies & Series", systemImage: "magnifyingglass",
                                           description: Text("Find something to request."))
                } else if !isLoading && results.isEmpty && errorMessage == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies & Series")
            .task(id: query) {
                // Debounce typing.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await search()
            }
            .navigationTitle("New Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private func requestButton(for item: DiscoverItem) -> some View {
        if requesting.contains(item.id) {
            ProgressView()
        } else if requested.contains(item.id) {
            StatusBadge(state: .pendingApproval)
        } else if let state = item.state {
            StatusBadge(state: state)
        } else {
            Button("Request") { Task { await request(item) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let client = seerr.client, !trimmed.isEmpty else {
            results = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await client.search(trimmed)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func request(_ item: DiscoverItem) async {
        guard let client = seerr.client else { return }
        requesting.insert(item.id)
        defer { requesting.remove(item.id) }
        do {
            try await client.request(item)
            requested.insert(item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
