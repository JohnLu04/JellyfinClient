import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @AppStorage(SettingsKeys.streamingMbit) private var streamingMbit = 0.0
    @AppStorage(SettingsKeys.downloadMbit) private var downloadMbit = 4.0
    @AppStorage(SettingsKeys.videoPlayer) private var videoPlayer = PlayerKind.defaultKind.rawValue
    @State private var confirmSignOut = false

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
                    StreamingQualityControl(mbit: $streamingMbit)
                } header: {
                    Text("Streaming · \(Bitrate.label(streamingMbit))")
                } footer: {
                    Text("Default for every title; you can still change it on each title's page. If a video's bitrate is above the limit, the server transcodes it.")
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
            .confirmationDialog("Sign out of this server?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
            } message: {
                Text("Your downloads stay on this iPhone.")
            }
        }
    }
}
