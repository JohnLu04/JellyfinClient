import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(SeerrStore.self) private var seerr
    @AppStorage(SettingsKeys.streamingMbit) private var streamingMbit = 0.0
    @AppStorage(SettingsKeys.downloadMbit) private var downloadMbit = 4.0
    @AppStorage(SettingsKeys.videoPlayer) private var videoPlayer = PlayerKind.defaultKind.rawValue
    @AppStorage(SettingsKeys.autoplayTrailers) private var autoplayTrailers = true
    @AppStorage(SettingsKeys.bufferSeconds) private var bufferSeconds = PlaybackBuffer.defaultSeconds
    @State private var confirmSignOut = false
    @Environment(\.dismiss) private var dismiss

    private var selectedPlayer: PlayerKind { PlayerKind(rawValue: videoPlayer) ?? .defaultKind }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Name", value: app.session?.serverName ?? "–")
                    LabeledContent("Address", value: app.session?.serverURL.absoluteString ?? "–")
                    LabeledContent("User", value: app.session?.userName ?? "–")
                }

                Section {
                    NavigationLink {
                        SeerrSetupView()
                    } label: {
                        HStack(spacing: 12) {
                            ServiceIcon(size: 30)
                            Text("Seerr")
                            Spacer()
                            Text(seerr.isConnected ? "Connected" : "Not connected")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Requests")
                } footer: {
                    Text("Discover and request movies and series in the Request tab.")
                }

                Section {
                    Picker("Video Player", selection: $videoPlayer) {
                        ForEach(PlayerKind.allCases) { kind in
                            Text(kind.title).tag(kind.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Video Player")
                } footer: {
                    Text(selectedPlayer.summary)
                }

                Section {
                    Toggle("Show Trailers", isOn: $autoplayTrailers)
                } footer: {
                    Text("Shows a play button at the top of movie and series pages that plays the trailer, preferring German trailers.")
                }

                Section {
                    StreamingQualityControl(mbit: $streamingMbit)
                } header: {
                    Text("Streaming · \(Bitrate.label(streamingMbit))")
                } footer: {
                    Text("Default for every title; you can still change it on each title's page. If a video's bitrate is above the limit, the server transcodes it.")
                }

                Section {
                    Stepper(value: $bufferSeconds, in: PlaybackBuffer.range, step: PlaybackBuffer.step) {
                        LabeledContent("Buffer Ahead", value: PlaybackBuffer.label(bufferSeconds))
                    }
                    Slider(value: $bufferSeconds, in: PlaybackBuffer.range, step: PlaybackBuffer.step) {
                        Text("Buffer Ahead")
                    } minimumValueLabel: {
                        Text(PlaybackBuffer.label(PlaybackBuffer.range.lowerBound)).font(.caption)
                    } maximumValueLabel: {
                        Text(PlaybackBuffer.label(PlaybackBuffer.range.upperBound)).font(.caption)
                    }
                } header: {
                    Text("Buffer · \(PlaybackBuffer.label(bufferSeconds))")
                } footer: {
                    Text("How much of the video is loaded ahead, up to 10 minutes. More buffer bridges longer network drops but uses more memory and data; with mpv the buffer is capped at \(PlaybackBuffer.memoryLimitMiB) MB on this iPhone. Applies from the next video you start.")
                }

                Section {
                    BitrateStepper(mbit: $downloadMbit)
                } header: {
                    Text("Transcoded Downloads")
                } footer: {
                    Text("Default bitrate for transcoded downloads. You can also download the original file.")
                }

                Section("Storage") {
                    LabeledContent("Downloads", value: ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                }

                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Version \(JellyfinAPI.clientVersion)")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Sign out of this server?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
            } message: {
                Text("Your downloads stay on this iPhone.")
            }
        }
    }
}
