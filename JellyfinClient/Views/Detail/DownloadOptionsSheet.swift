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
    @AppStorage(SettingsKeys.downloadAllAudio) private var allAudio = true
    @AppStorage(SettingsKeys.downloadSubtitles) private var subtitles = true

    private var source: MediaSourceInfo? { item.primaryMediaSource }
    private var mainAudio: MediaStream? {
        let index = TrackSelection.defaults(for: source).audioIndex
        return source?.audioStreams.first { $0.index == index }
    }
    private var extraAudioCount: Int { max(0, (source?.audioStreams.count ?? 0) - 1) }
    /// Subtitles loaded as files: all text ones when transcoding, only external ones for originals.
    private var subtitleFileCount: Int {
        (source?.subtitleStreams ?? []).filter { $0.isTextSubtitle && (mode == .transcoded || $0.isExternal == true) }.count
    }
    private var imageSubtitleCount: Int { (source?.subtitleStreams ?? []).filter { !$0.isTextSubtitle }.count }

    init(item: BaseItem) {
        self.item = item
        let stored = UserDefaults.standard.object(forKey: SettingsKeys.downloadMbit) as? Double
        _mbit = State(initialValue: Bitrate.snap(stored ?? 4))
        // mpv plays any container offline, so the original file is the better default there.
        let originalPlays = PlayerKind.current == .mpv || Self.isNativeContainer(item)
        _mode = State(initialValue: originalPlays ? .original : .transcoded)
    }

    @ViewBuilder
    private var tracksSection: some View {
        let audioCount = source?.audioStreams.count ?? 0
        if audioCount > 1 || subtitleFileCount > 0 || imageSubtitleCount > 0 {
            Section {
                if mode == .transcoded, extraAudioCount > 0 {
                    Toggle(isOn: $allAudio) {
                        Text("All Audio Tracks (\(audioCount))")
                    }
                }
                if subtitleFileCount > 0 {
                    Toggle(isOn: $subtitles) {
                        Text(mode == .original ? "External Subtitles (\(subtitleFileCount))" : "Subtitles (\(subtitleFileCount))")
                    }
                }
            } header: {
                Text("Audio & Subtitles")
            } footer: {
                Text(tracksFooter)
            }
        }
    }

    private var tracksFooter: String {
        var lines: [String] = []
        switch mode {
        case .original:
            lines.append(String(localized: "The original file contains all of its embedded audio tracks and subtitles."))
        case .transcoded:
            if let mainAudio {
                lines.append(String(localized: "The video file carries one audio track (\(mainAudio.label))."))
            }
            if extraAudioCount > 0, allAudio {
                lines.append(String(localized: "The other audio tracks are loaded as extra files afterwards; the server converts each of them once, which takes extra time."))
            }
            if imageSubtitleCount > 0 {
                lines.append(String(localized: "Image subtitles (PGS, VobSub) can't be saved separately – download the original to keep them."))
            }
        }
        if PlayerKind.current == .native, mode == .transcoded || subtitleFileCount > 0 {
            lines.append(String(localized: "Extra audio tracks and subtitle files play in mpv; the Apple player only plays the video file's own track."))
        }
        return lines.joined(separator: " ")
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

                tracksSection

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
                        downloads.start(item: item, api: api, mbit: mode == .transcoded ? mbit : nil,
                                        tracks: DownloadTrackOptions(allAudioTracks: allAudio, subtitles: subtitles))
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
