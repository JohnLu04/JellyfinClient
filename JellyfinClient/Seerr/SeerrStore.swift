import Foundation
import Observation
import Security
import SwiftUI

/// Address and API key of the Seerr server.
struct SeerrConfig: Codable, Equatable, Hashable, Sendable {
    /// Normalized, without trailing slash, e.g. "http://192.168.1.10:5055".
    var baseURL: String
    var apiKey: String
}

/// The connected Seerr server (kept in the Keychain) and its client.
@Observable @MainActor
final class SeerrStore {
    static let shared = SeerrStore()

    private(set) var config: SeerrConfig?

    var client: SeerrClient? { config.map { SeerrClient(config: $0) } }
    var isConnected: Bool { config != nil }

    private init() {
        config = SeerrKeychain.load()
    }

    /// Checks the address and key against `/api/v1/status` and saves them on success.
    /// Returns the Seerr version.
    @discardableResult
    func connect(address: String, apiKey: String) async throws -> String {
        guard let url = ServerAddress.normalize(address) else { throw SeerrError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = SeerrConfig(baseURL: url.absoluteString, apiKey: key)
        let version = try await SeerrClient(config: candidate).status()
        SeerrKeychain.save(candidate)
        config = candidate
        return version
    }

    func disconnect() {
        SeerrKeychain.clear()
        config = nil
    }
}

private enum SeerrKeychain {
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "JellyfinClient") + ".seerr",
            kSecAttrAccount as String: "current",
        ]
    }

    static func load() -> SeerrConfig? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SeerrConfig.self, from: data)
    }

    static func save(_ config: SeerrConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Setup

/// Address + API key form, used in Settings and from the Request tab.
struct SeerrSetupView: View {
    @Environment(SeerrStore.self) private var seerr
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var apiKey = ""
    @State private var isConnecting = false
    @State private var message: String?
    @State private var failed = false
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address, prompt: Text("192.168.1.10:5055 or https://…"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Seerr Server")
            } footer: {
                Text("Find the API key in Seerr under Settings → General → API Key. Works with Seerr, Jellyseerr and Overseerr.")
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text(seerr.isConnected ? "Save" : "Connect")
                        if isConnecting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.isEmpty || isConnecting)
            } footer: {
                if let message {
                    Text(message).foregroundStyle(failed ? Color.red : Color.green)
                }
            }

            if seerr.isConnected {
                Section {
                    Button("Disconnect Seerr", role: .destructive) { confirmDisconnect = true }
                }
            }
        }
        .navigationTitle("Seerr")
        .onAppear {
            guard address.isEmpty else { return }
            if let config = seerr.config {
                address = config.baseURL
                apiKey = config.apiKey
            }
            #if DEBUG
            // Debug builds only: prefill from launch environment (JF_DEBUG_SEERR / _SEERR_KEY) for automated testing.
            let env = ProcessInfo.processInfo.environment
            if let debugAddress = env["JF_DEBUG_SEERR"] { address = debugAddress }
            if let debugKey = env["JF_DEBUG_SEERR_KEY"] { apiKey = debugKey }
            #endif
        }
        .confirmationDialog("Disconnect Seerr?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                seerr.disconnect()
                address = ""
                apiKey = ""
                message = nil
            }
        }
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            let version = try await seerr.connect(address: address, apiKey: apiKey)
            failed = false
            message = String(localized: "Connected to Seerr \(version).")
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}
