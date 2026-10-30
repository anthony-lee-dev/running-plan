import APIClient
import Foundation

/// Why signing in (or staying signed in) failed, in terms a screen can explain.
enum SignInError: Error, Equatable {
    case invalidEmail
    case wrongCode
    case tooManyRequests
    case offline
    case server
}

/// The signed-in state for one API base URL: email sign-in, and refreshing the access token one call at a time.
/// Keep one per base URL for the life of the app: the server revokes every token when a rotated refresh token is
/// reused, so two refreshes at once would sign the user out.
actor AuthSession {
    /// Calls the auth endpoints directly, without `AuthMiddleware`.
    private let client: Client
    private let store: TokenStoring
    private var tokens: StoredTokens?
    private var refreshing: Task<StoredTokens?, Error>?

    init(client: Client, store: TokenStoring) {
        self.client = client
        self.store = store
        tokens = store.load()
    }

    var isSignedIn: Bool { tokens != nil }

    func accessToken() -> String? { tokens?.accessToken }

    /// Sends a one-time code. The server answers the same whether or not an account exists.
    func startEmailSignIn(email: String) async throws {
        let output = try await call { try await self.client.startEmailSignIn(body: .json(.init(email: email))) }
        switch output {
        case .accepted: return
        case .badRequest: throw SignInError.invalidEmail
        case .tooManyRequests: throw SignInError.tooManyRequests
        case .undocumented: throw SignInError.server
        }
    }

    /// Exchanges the emailed code for tokens and keeps them.
    func verify(email: String, code: String) async throws {
        let output = try await call {
            try await self.client.verifyEmailSignIn(body: .json(.init(email: email, code: code, clientType: .ios)))
        }
        switch output {
        case .ok(let ok):
            let pair = try ok.body.json
            try keep(StoredTokens(accessToken: pair.accessToken, refreshToken: pair.refreshToken, userId: pair.userId))
        case .badRequest, .unauthorized: throw SignInError.wrongCode
        case .tooManyRequests: throw SignInError.tooManyRequests
        case .undocumented: throw SignInError.server
        }
    }

    func signOut() {
        tokens = nil
        store.clear()
    }

    /// The token to retry with after `rejected` got a 401: the current one if another call already refreshed, else
    /// a refreshed one. Nil when signed out, including when the server refuses the refresh token. Offline or a server
    /// error throws and keeps the tokens.
    func tokenAfterRejecting(_ rejected: String) async throws -> String? {
        guard let current = tokens else { return nil }
        if current.accessToken != rejected, refreshing == nil { return current.accessToken }
        if let refreshing { return try await refreshing.value?.accessToken }

        let task = Task { try await self.requestRefresh(current.refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        guard let fresh = try await task.value else {
            signOut()
            return nil
        }
        // Saved before anyone uses it: the old refresh token no longer works.
        try? keep(fresh)
        return fresh.accessToken
    }

    /// A new pair, or nil when the server refuses the refresh token.
    private func requestRefresh(_ refreshToken: String) async throws -> StoredTokens? {
        let output = try await call { try await self.client.refreshToken(body: .json(.init(refreshToken: refreshToken))) }
        switch output {
        case .ok(let ok):
            let pair = try ok.body.json
            return StoredTokens(accessToken: pair.accessToken, refreshToken: pair.refreshToken, userId: pair.userId)
        case .badRequest, .unauthorized: return nil
        case .undocumented: throw SignInError.server
        }
    }

    private func keep(_ fresh: StoredTokens) throws {
        tokens = fresh
        try store.save(fresh)
    }

    /// Runs a call, turning transport failures into `SignInError` (cancellation passes through).
    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            throw underlying is URLError ? SignInError.offline : SignInError.server
        }
    }
}
