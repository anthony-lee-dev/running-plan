import APIClient
import Foundation

extension APIConfiguration {
    /// The one session for this run's API base URL. Never make a second: see `AuthSession`.
    static let liveSession = AuthSession(
        client: Client(serverURL: baseURL, transport: URLSessionTransport()),
        store: liveTokenStore(baseURL: baseURL, bundleID: Bundle.main.bundleIdentifier ?? "runningplan", defaults: .standard)
    )

    /// A client that signs its calls in through `liveSession`.
    static func liveSignedInClient() -> Client {
        Client(serverURL: baseURL, transport: URLSessionTransport(), middlewares: [AuthMiddleware(session: liveSession)])
    }

    /// The Keychain store for this base URL. The `-auth.reset YES` launch argument signs out first: Keychain items
    /// outlive a reinstall, so UI tests pass it to start signed out.
    static func liveTokenStore(baseURL: URL, bundleID: String, defaults: UserDefaults) -> KeychainTokenStore {
        let store = KeychainTokenStore(service: KeychainTokenStore.service(for: baseURL, bundleID: bundleID))
        if defaults.bool(forKey: "auth.reset") { store.clear() }
        return store
    }
}
