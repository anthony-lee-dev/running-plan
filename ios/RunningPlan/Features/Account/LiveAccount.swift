import APIClient
import Foundation

extension APIConfiguration {
    /// The one session for this run's API base URL. Never make a second: see `AuthSession`.
    static let liveSession = AuthSession(
        client: client(serverURL: baseURL, transport: URLSessionTransport()),
        store: liveTokenStore(baseURL: baseURL, bundleID: Bundle.main.bundleIdentifier ?? "runningplan", defaults: .standard)
    )

    /// A client that signs its calls in through `liveSession`.
    static func liveSignedInClient() -> Client {
        client(serverURL: baseURL, transport: URLSessionTransport(), middlewares: [AuthMiddleware(session: liveSession)])
    }

    /// The Keychain store for this base URL. The `-auth.reset YES` launch argument signs out first: Keychain items
    /// outlive a reinstall, so UI tests pass it to start signed out. A Debug build also takes `-auth.seed
    /// "<access>|<refresh>|<userId>"` (after the reset) to start signed in, so a UI test that is not about sign-in
    /// can skip it; the tokens come from the UI-test API's `/__test/seed`.
    static func liveTokenStore(baseURL: URL, bundleID: String, defaults: UserDefaults) -> KeychainTokenStore {
        let store = KeychainTokenStore(service: KeychainTokenStore.service(for: baseURL, bundleID: bundleID))
        if defaults.bool(forKey: "auth.reset") { store.clear() }
        #if DEBUG
        if let seed = defaults.string(forKey: "auth.seed") {
            let parts = seed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, !parts.contains("") {
                try? store.save(StoredTokens(accessToken: parts[0], refreshToken: parts[1], userId: parts[2]))
            }
        }
        #endif
        return store
    }
}
