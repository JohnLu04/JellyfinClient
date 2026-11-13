import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    private(set) var session: ServerSession?

    var api: JellyfinAPI? { session.map(JellyfinAPI.init(session:)) }

    init() {
        session = SessionStorage.load()
    }

    func signIn(serverURL: URL, username: String, password: String) async throws {
        let anonymous = JellyfinAPI(baseURL: serverURL)
        let info = try await anonymous.publicSystemInfo()
        let auth = try await anonymous.authenticate(username: username, password: password)
        let newSession = ServerSession(
            serverURL: serverURL,
            serverName: info.serverName,
            userId: auth.user.id,
            userName: auth.user.name ?? username,
            accessToken: auth.accessToken
        )
        SessionStorage.save(newSession)
        session = newSession
    }

    func signOut() async {
        if let api { try? await api.logout() }
        SessionStorage.clear()
        session = nil
    }

    /// Call from views when a request fails; drops an expired session.
    func handle(_ error: Error) async {
        if case APIError.unauthorized = error { await signOut() }
    }
}
