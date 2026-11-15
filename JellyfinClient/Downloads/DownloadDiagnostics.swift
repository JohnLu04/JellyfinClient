import Foundation
import SwiftUI

/// A short, local log of what the downloader did (start, retries, errors with their codes), viewable
/// and copyable from the download list, so problems on a real iPhone can be traced.
enum DownloadDiagnostics {
    private static let queue = DispatchQueue(label: "DownloadDiagnostics")
    private static let maxLines = 300
    nonisolated(unsafe) private static var lines: [String]?

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("download-log.txt")
    }

    /// Thread-safe; callable from the URLSession delegate queue.
    static func log(_ message: String) {
        let stamp = Date.now.formatted(.dateTime.day().month().hour().minute().second())
        queue.async {
            var current = loadedLines()
            current.append("\(stamp)  \(message)")
            if current.count > maxLines { current.removeFirst(current.count - maxLines) }
            lines = current
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? current.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func entries() -> [String] {
        queue.sync { loadedLines() }
    }

    static func clear() {
        queue.sync {
            lines = []
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func loadedLines() -> [String] {
        if let lines { return lines }
        let loaded = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        lines = loaded
        return loaded
    }

    /// "NSCocoaErrorDomain 513 (…) ← NSPOSIXErrorDomain 1" – the codes say more than the message.
    static func describe(_ error: NSError) -> String {
        var text = "\(error.domain) \(error.code): \(error.localizedDescription)"
        if let reason = error.userInfo["NSURLErrorBackgroundTaskCancelledReasonKey"] {
            text += " [background reason \(reason)]"
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.domain) \(underlying.code)"
        }
        return text
    }
}

struct DownloadLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                if entries.isEmpty {
                    ContentUnavailableView("No Entries", systemImage: "doc.text",
                                           description: Text("Download events and errors appear here."))
                        .padding(.top, 80)
                } else {
                    Text(entries.reversed().joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .navigationTitle("Download Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = entries.joined(separator: "\n")
                    }
                    .disabled(entries.isEmpty)
                    Spacer()
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        DownloadDiagnostics.clear()
                        entries = []
                    }
                    .disabled(entries.isEmpty)
                }
            }
            .onAppear { entries = DownloadDiagnostics.entries() }
        }
    }
}
