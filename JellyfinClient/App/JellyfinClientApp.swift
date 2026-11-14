import AVFoundation
import SwiftUI

@main
struct JellyfinClientApp: App {
    @State private var appModel = AppModel()
    @State private var downloads = DownloadManager.shared
    @State private var seerr = SeerrStore.shared

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(downloads)
                .environment(seerr)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.session != nil {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .animation(.default, value: app.session)
        .preferredColorScheme(.dark)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") { HomeView() }
            Tab("Favorites", systemImage: "heart.fill") { FavoritesView() }
            Tab("Library", systemImage: "rectangle.stack.fill") { LibraryView() }
            Tab("Request", systemImage: "plus.rectangle.on.rectangle") { RequestTabView() }
        }
    }
}
