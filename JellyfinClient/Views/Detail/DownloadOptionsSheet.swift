import SwiftUI

// MARK: - Download options

struct DownloadOptionsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    let item: BaseItem

    private enum Mode: Hashable { case original, transcoded }
    @State private var mode: Mode
    @State private var mbit: Double

    init(item: BaseItem) {
        self.item = item
        let stored = UserDefaults.standard.object(forKey: SettingsKeys.downloadMbit) as? Double
        _mbit = State(initialValue: Bitrate.snap(stored ?? 4))
        // mpv plays any container offline, so the original file is the better default there.
        let originalPlays = PlayerKind.current == .mpv || Self.isNativeContainer(item)
        _mode = State(initialValue: originalPlays ? .original : .transcoded)
    }

    private static func isNativeContainer(_ item: BaseItem) -> Bool {
        guard let container = item.primaryMediaSource?.container?.lowercased() else { return false }
        return container.split(separator: ",").contains { ["mp4", "m4v", "mov"].contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Version", selection: $mode) {
                        Text("Original").tag(Mode.original)
                        Text("Transcoded").tag(Mode.transcoded)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    switch mode {
                    case .original:
                        Text("Downloads the unchanged file. Requires the “Allow media downloading” permission on the server.")
                    case .transcoded:
                        Text("The server converts the video to H.264/AAC (MP4) at the chosen bitrate. Requires the transcoding permission. The download takes about as long as the server needs to transcode.")
                    }
                }

                if mode == .transcoded {
                    Section("Bitrate") {
                        BitrateStepper(mbit: $mbit)
                    }
                }

                Section {
                    if let size = estimatedSize {
                        LabeledContent(mode == .original ? "File size" : "Estimated size",
                                       value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if mode == .original, let container = item.primaryMediaSource?.container {
                        LabeledContent("Format", value: container.uppercased())
                        if !Self.isNativeContainer(item) && PlayerKind.current == .native {
                            Label("The Apple player can't play this format offline. Choose “Transcoded” or switch to mpv in Settings.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        guard let api = app.api else { return }
                        downloads.start(item: item, api: api, mbit: mode == .transcoded ? mbit : nil)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var estimatedSize: Int64? {
        switch mode {
        case .original: return item.primaryMediaSource?.size
        case .transcoded: return Bitrate.estimatedBytes(mbit: mbit, runTimeTicks: item.runTimeTicks)
        }
    }
}
