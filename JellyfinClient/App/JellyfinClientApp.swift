import AVFoundation
import SwiftUI

@main
struct JellyfinClientApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

/// Hands background-download wake-ups to the download manager.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = DownloadManager.shared      // reattach to transfers that kept running while the app was gone
        return true
    }

    /// iOS relaunched or woke the app because downloads finished or need attention.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else { return completionHandler() }
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
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
            // Set apart from the other tabs at the bottom right, with a magnifying glass.
            Tab("Search", systemImage: "magnifyingglass", role: Self.searchRole) { SearchView() }
        }
    }

    /// iOS 27 shows a separate button at the trailing end of the tab bar for the "prominent" role;
    /// on iOS 18–26 the search role does that. `.prominent` needs the iOS 27 SDK (Xcode 27, Swift 6.4).
    private static var searchRole: TabRole {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        return .search
    }
}
