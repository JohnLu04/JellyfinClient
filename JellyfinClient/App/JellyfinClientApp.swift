import AVFoundation
import SwiftUI

@main
struct JellyfinClientApp: App {
    @State private var appModel = AppModel()
    @State private var downloads = DownloadManager.shared

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(downloads)
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
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") { HomeView() }
            Tab("Downloads", systemImage: "arrow.down.circle.fill") { DownloadsView() }
            Tab("Settings", systemImage: "gearshape.fill") { SettingsView() }
        }
    }
}
