import SwiftUI

/// Watched / unwatched marks made in this session, so every card shows them right away without its
/// screen reloading. Marking also clears the playback position on the server, so a marked item shows
/// no progress until it is played again.
@Observable @MainActor
final class WatchedStore {
    static let shared = WatchedStore()

    private var marks: [String: Bool] = [:]
    private(set) var lastError: String?

    private init() {}

    func isPlayed(_ item: BaseItem) -> Bool {
        marks[item.id] ?? (item.userData?.played == true)
    }

    /// The resume position as a fraction, unless the item was marked since it was loaded.
    func progress(_ item: BaseItem) -> Double? {
        marks[item.id] == nil ? item.progressFraction : nil
    }

    /// Only movies, episodes, videos and series can be marked.
    static func canMark(_ item: BaseItem) -> Bool {
        item.kind == .playable || item.kind == .series
    }

    func toggle(_ item: BaseItem, api: JellyfinAPI?) {
        set(item, played: !isPlayed(item), api: api)
    }

    func set(_ item: BaseItem, played: Bool, api: JellyfinAPI?) {
        guard let api else { return }
        let before = marks[item.id]
        withAnimation(.easeInOut(duration: 0.2)) { marks[item.id] = played }
        Task {
            do {
                try await api.setPlayed(itemId: item.id, played)
                NotificationCenter.default.post(name: .playedStateDidChange, object: item.id)
            } catch {
                withAnimation { marks[item.id] = before }
                lastError = error.localizedDescription
            }
        }
    }

    /// The item is played again: its state comes from the server from now on.
    func forget(_ ids: String?...) {
        for id in ids.compactMap({ $0 }) { marks[id] = nil }
    }
}

/// The eye on artwork of a watched title; tapping it marks the title as not watched.
struct WatchedEyeButton: View {
    @Environment(AppModel.self) private var app
    let item: BaseItem
    var size: CGFloat = 26

    var body: some View {
        Button {
            WatchedStore.shared.set(item, played: false, api: app.api)
        } label: {
            Image(systemName: "eye.fill")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.accentColor, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 3)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watched · Mark as Unwatched")
        .transition(.scale.combined(with: .opacity))
    }
}

extension View {
    /// Long press: mark the title as watched or not watched.
    func watchedContextMenu(_ item: BaseItem) -> some View {
        modifier(WatchedContextMenu(item: item))
    }
}

private struct WatchedContextMenu: ViewModifier {
    @Environment(AppModel.self) private var app
    let item: BaseItem

    func body(content: Content) -> some View {
        if WatchedStore.canMark(item) {
            content.contextMenu {
                if WatchedStore.shared.isPlayed(item) {
                    Button("Mark as Unwatched", systemImage: "eye.slash") {
                        WatchedStore.shared.set(item, played: false, api: app.api)
                    }
                } else {
                    Button("Mark as Watched", systemImage: "eye") {
                        WatchedStore.shared.set(item, played: true, api: app.api)
                    }
                }
            }
        } else {
            content
        }
    }
}
