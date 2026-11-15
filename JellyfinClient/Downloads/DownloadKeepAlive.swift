import Foundation
#if compiler(>=6.2)
import BackgroundTasks
#endif

/// Keeps the app running in the background while downloads are queued (iOS 26+), like Streamyfin's
/// continued-processing keeper.
///
/// The transfer itself never needs this: it runs in the background URLSession either way. What it
/// adds is that the app isn't suspended between downloads, so the next episode in the queue starts
/// immediately instead of whenever iOS next wakes the app, and progress keeps updating. iOS shows its
/// own progress indicator for it while the app is in the background.
///
/// One task covers the whole queue. It can only be submitted while the app is in the foreground, so
/// it is requested when the user starts a download; afterwards it is just updated and ended once the
/// queue is empty. Before iOS 26, or if the system declines, everything still works without it.
@MainActor
enum DownloadKeepAlive {
    static func begin(title: String, subtitle: String) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { Keeper.shared.ensureRunning(title: title, subtitle: subtitle) }
        #endif
    }

    static func update(title: String, subtitle: String) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { Keeper.shared.updateTitle(title, subtitle: subtitle) }
        #endif
    }

    static func progress(completed: Int64, total: Int64) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { Keeper.shared.updateProgress(completed: completed, total: total) }
        #endif
    }

    static func end() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { Keeper.shared.finish() }
        #endif
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private final class Keeper: @unchecked Sendable {
    static let shared = Keeper()

    /// Must be listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    private let identifier = (Bundle.main.bundleIdentifier ?? "JellyfinClient") + ".downloads"
    private let queue = DispatchQueue(label: "DownloadKeepAlive")
    private var task: BGContinuedProcessingTask?
    private var isRegistered = false
    private var isPending = false

    /// Registering an identifier that Info.plist doesn't list crashes. Sideloading tools sometimes
    /// change the bundle id without updating that list, so check first and just skip the keeper then.
    private lazy var isPermitted: Bool = {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.contains(identifier)
    }()

    func ensureRunning(title: String, subtitle: String) {
        queue.async {
            if let task = self.task {
                task.updateTitle(title, subtitle: subtitle)
                return
            }
            guard !self.isPending else { return }
            guard self.isPermitted else {
                DownloadDiagnostics.log("Background keep-alive unavailable: \(self.identifier) isn't listed in Info.plist")
                return
            }
            self.registerIfNeeded()
            let request = BGContinuedProcessingTaskRequest(identifier: self.identifier, title: title, subtitle: subtitle)
            do {
                try BGTaskScheduler.shared.submit(request)
                self.isPending = true
                DownloadDiagnostics.log("Background keep-alive requested")
            } catch {
                downloadLog.error("Keep-alive submit failed: \(error.localizedDescription, privacy: .public)")
                DownloadDiagnostics.log("Background keep-alive refused by iOS: \(DownloadDiagnostics.describe(error as NSError))")
            }
        }
    }

    func updateTitle(_ title: String, subtitle: String) {
        queue.async { self.task?.updateTitle(title, subtitle: subtitle) }
    }

    func updateProgress(completed: Int64, total: Int64) {
        queue.async {
            guard let task = self.task, total > 0 else { return }
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = min(completed, total)
        }
    }

    func finish() {
        queue.async {
            self.isPending = false
            guard let task = self.task else { return }
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
            self.task = nil
            DownloadDiagnostics.log("Background keep-alive finished (queue empty)")
        }
    }

    private func registerIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: queue) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            continued.progress.totalUnitCount = 100
            continued.progress.completedUnitCount = 0
            // The system ended it (or the user tapped stop). The downloads keep going in the
            // background session; only the app gets suspended again.
            continued.expirationHandler = {
                self.queue.async {
                    DownloadDiagnostics.log("Background keep-alive ended by iOS (downloads continue, just slower in the background)")
                    self.task?.setTaskCompleted(success: false)
                    self.task = nil
                }
            }
            self.task = continued
            self.isPending = false
            DownloadDiagnostics.log("Background keep-alive running – the app keeps working in the background")
        }
    }
}
#endif
