import Foundation
import Security

struct ServerSession: Codable, Equatable {
    var serverURL: URL
    var serverName: String?
    var userId: String
    var userName: String
    var accessToken: String
}

/// Keeps the signed-in session (including the access token) in the Keychain.
enum SessionStorage {
    private static let service = (Bundle.main.bundleIdentifier ?? "JellyfinClient") + ".session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "current",
        ]
    }

    static func load() -> ServerSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServerSession.self, from: data)
    }

    static func save(_ session: ServerSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
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

enum ServerAddress {
    /// Accepts things like "192.168.1.10:8096", "jellyfin.example.com" or a pasted web UI URL.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var comps = URLComponents(string: text),
              let scheme = comps.scheme?.lowercased(), ["http", "https"].contains(scheme),
              comps.host?.isEmpty == false else { return nil }
        if let range = comps.path.range(of: "/web", options: [.caseInsensitive, .backwards]) {
            comps.path = String(comps.path[..<range.lowerBound])
        }
        while comps.path.hasSuffix("/") { comps.path.removeLast() }
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }
}
