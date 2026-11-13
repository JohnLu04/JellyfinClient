import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKeys.lastServerAddress) private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Field { case server, username, password }
    @FocusState private var focus: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Connect to your Jellyfin server")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("192.168.1.10:8096 or https://…", text: $serverAddress)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                } header: {
                    Text("Server")
                }

                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                } header: {
                    Text("Account")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView() } else { Text("Sign In").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Jellyfin")
            #if DEBUG
            .onAppear(perform: applyDebugPrefill)
            #endif
        }
    }

    #if DEBUG
    /// Debug builds only: prefill from launch environment (JF_DEBUG_SERVER / _USER / _PASSWORD) for automated testing.
    private func applyDebugPrefill() {
        let env = ProcessInfo.processInfo.environment
        if let server = env["JF_DEBUG_SERVER"] { serverAddress = server }
        if let user = env["JF_DEBUG_USER"] { username = user }
        if let pass = env["JF_DEBUG_PASSWORD"] { password = pass }
    }
    #endif

    private var canSubmit: Bool {
        !isWorking && !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func signIn() async {
        guard canSubmit else { return }
        guard let url = ServerAddress.normalize(serverAddress) else {
            errorMessage = String(localized: "That doesn't look like a valid server address.")
            return
        }
        focus = nil
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await app.signIn(serverURL: url,
                                 username: username.trimmingCharacters(in: .whitespaces),
                                 password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
