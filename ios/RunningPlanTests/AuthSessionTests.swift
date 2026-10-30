import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

/// Answers each request through a handler and records the operations it saw.
private final class ScriptedTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(operation: String, body: String?)] = []
    private let handler: @Sendable (String) async throws -> (HTTPResponse.Status, String)

    init(_ handler: @escaping @Sendable (String) async throws -> (HTTPResponse.Status, String)) {
        self.handler = handler
    }

    var operations: [String] { lock.withLock { seen.map(\.operation) } }
    var bodies: [String?] { lock.withLock { seen.map(\.body) } }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let text: String? = if let body { try await String(collecting: body, upTo: 100_000) } else { nil }
        lock.withLock { seen.append((operationID, text)) }
        let (status, json) = try await handler(operationID)
        var response = HTTPResponse(status: status)
        guard !json.isEmpty else { return (response, nil) }
        response.headerFields[.contentType] = status.code >= 400 ? "application/problem+json" : "application/json"
        return (response, HTTPBody(json))
    }
}

/// Keeps tokens in memory, like the Keychain store would.
final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StoredTokens?
    init(_ tokens: StoredTokens? = nil) { stored = tokens }
    func load() -> StoredTokens? { lock.withLock { stored } }
    func save(_ tokens: StoredTokens) throws { lock.withLock { stored = tokens } }
    func clear() { lock.withLock { stored = nil } }
}

private let userID = "6f1c2a4e-1b7d-4c1e-9a55-2f0b8f3c9d10"
private func pair(_ access: String, _ refresh: String) -> String {
    #"{"accessToken":"\#(access)","refreshToken":"\#(refresh)","tokenType":"Bearer","expiresIn":900,"scopes":["app","activities:write"],"userId":"\#(userID)"}"#
}
private func problem(_ status: Int) -> String {
    #"{"type":"about:blank","title":"No","status":\#(status)}"#
}
private func sentJSON(_ transport: ScriptedTransport) throws -> [String: Any] {
    let text = try #require(transport.bodies.first ?? nil)
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private let old = StoredTokens(accessToken: "a1", refreshToken: "r1", userId: userID)

private func session(_ transport: ScriptedTransport, _ store: TokenStoring) -> AuthSession {
    AuthSession(client: Client(serverURL: URL(string: "http://127.0.0.1:8790")!, transport: transport), store: store)
}

struct KeychainTokenStoreTests {
    @Test func savesLoadsAndClearsPerService() throws {
        let a = KeychainTokenStore(service: "tests.\(UUID().uuidString)")
        let b = KeychainTokenStore(service: "tests.\(UUID().uuidString)")
        defer { a.clear(); b.clear() }

        try a.save(old)
        #expect(a.load() == old)
        #expect(b.load() == nil, "each API base URL keeps its own tokens")

        let newer = StoredTokens(accessToken: "a2", refreshToken: "r2", userId: userID)
        try a.save(newer)
        #expect(a.load() == newer)

        a.clear()
        #expect(a.load() == nil)
    }

    @Test func serviceNamesTheAPIHostAndPort() {
        let service = KeychainTokenStore.service(for: URL(string: "http://127.0.0.1:8790")!, bundleID: "ca.example.app")
        #expect(service == "ca.example.app.tokens.127.0.0.1:8790")
        let deployed = KeychainTokenStore.service(for: URL(string: "https://api.example.dev")!, bundleID: "ca.example.app")
        #expect(deployed == "ca.example.app.tokens.api.example.dev")
    }
}

struct LiveTokenStoreTests {
    @Test func theResetArgumentSignsOut() throws {
        let defaults = try #require(UserDefaults(suiteName: "tests.\(UUID().uuidString)"))
        let url = URL(string: "http://127.0.0.1:\(Int.random(in: 20_000...60_000))")!
        let bundleID = "tests.\(UUID().uuidString)"
        let store = APIConfiguration.liveTokenStore(baseURL: url, bundleID: bundleID, defaults: defaults)
        defer { store.clear() }
        try store.save(old)

        #expect(APIConfiguration.liveTokenStore(baseURL: url, bundleID: bundleID, defaults: defaults).load() == old)
        defaults.set(true, forKey: "auth.reset")
        #expect(APIConfiguration.liveTokenStore(baseURL: url, bundleID: bundleID, defaults: defaults).load() == nil)
    }
}

struct AuthSessionSignInTests {
    @Test func verifyStoresTheTokens() async throws {
        let transport = ScriptedTransport { _ in (.ok, pair("a1", "r1")) }
        let store = MemoryTokenStore()
        let auth = session(transport, store)

        try await auth.verify(email: "runner@example.com", code: "123456")

        #expect(store.load() == old)
        #expect(await auth.isSignedIn)
        #expect(try sentJSON(transport)["clientType"] as? String == "ios")
    }

    @Test func startAcceptsA202() async throws {
        let transport = ScriptedTransport { _ in (.accepted, "") }
        try await session(transport, MemoryTokenStore()).startEmailSignIn(email: "runner@example.com")
        #expect(transport.operations == ["startEmailSignIn"])
    }

    @Test(arguments: [
        (HTTPResponse.Status.badRequest, SignInError.invalidEmail),
        (.tooManyRequests, .tooManyRequests),
    ])
    func startExplainsFailures(status: HTTPResponse.Status, expected: SignInError) async {
        let transport = ScriptedTransport { _ in (status, problem(status.code)) }
        await #expect(throws: expected) { try await session(transport, MemoryTokenStore()).startEmailSignIn(email: "x@example.com") }
    }

    @Test(arguments: [
        (HTTPResponse.Status.unauthorized, SignInError.wrongCode),
        (.badRequest, .wrongCode),
        (.tooManyRequests, .tooManyRequests),
    ])
    func verifyExplainsFailures(status: HTTPResponse.Status, expected: SignInError) async {
        let transport = ScriptedTransport { _ in (status, problem(status.code)) }
        let store = MemoryTokenStore()
        await #expect(throws: expected) { try await session(transport, store).verify(email: "x@example.com", code: "000000") }
        #expect(store.load() == nil)
    }

    @Test func verifyOfflineIsAnOfflineError() async {
        let transport = ScriptedTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: SignInError.offline) { try await session(transport, MemoryTokenStore()).verify(email: "x@example.com", code: "000000") }
    }

    @Test func signOutClearsTheStore() async {
        let store = MemoryTokenStore(old)
        let auth = session(ScriptedTransport { _ in (.ok, "") }, store)
        await auth.signOut()
        #expect(store.load() == nil)
        #expect(await !auth.isSignedIn)
    }
}

struct AuthSessionRefreshTests {
    @Test func aRejectedTokenIsRefreshedAndSavedBeforeItIsUsed() async throws {
        let transport = ScriptedTransport { _ in (.ok, pair("a2", "r2")) }
        let store = MemoryTokenStore(old)
        let auth = session(transport, store)

        let token = try await auth.tokenAfterRejecting("a1")

        #expect(token == "a2")
        #expect(store.load()?.refreshToken == "r2")
        #expect(try sentJSON(transport)["refreshToken"] as? String == "r1")
    }

    @Test func aStaleRejectionUsesTheCurrentTokenWithoutRefreshing() async throws {
        let transport = ScriptedTransport { _ in (.ok, pair("a3", "r3")) }
        let auth = session(transport, MemoryTokenStore(old))

        let token = try await auth.tokenAfterRejecting("a0")

        #expect(token == "a1")
        #expect(transport.operations.isEmpty)
    }

    @Test func concurrentRejectionsRefreshOnce() async throws {
        // Reusing a rotated refresh token revokes the family, so a second refresh would sign the user out.
        let transport = ScriptedTransport { _ in
            try await Task.sleep(for: .milliseconds(100))
            return (.ok, pair("a2", "r2"))
        }
        let auth = session(transport, MemoryTokenStore(old))

        async let first = auth.tokenAfterRejecting("a1")
        async let second = auth.tokenAfterRejecting("a1")
        async let third = auth.tokenAfterRejecting("a1")
        let tokens = try await [first, second, third]

        #expect(tokens == ["a2", "a2", "a2"])
        #expect(transport.operations == ["refreshToken"])
    }

    @Test(arguments: [HTTPResponse.Status.unauthorized, .badRequest])
    func aRefusedRefreshSignsOut(status: HTTPResponse.Status) async throws {
        let transport = ScriptedTransport { _ in (status, problem(status.code)) }
        let store = MemoryTokenStore(old)
        let auth = session(transport, store)

        let token = try await auth.tokenAfterRejecting("a1")

        #expect(token == nil)
        #expect(store.load() == nil)
        #expect(await !auth.isSignedIn)
    }

    @Test func anOfflineRefreshKeepsTheTokens() async {
        let transport = ScriptedTransport { _ in throw URLError(.notConnectedToInternet) }
        let store = MemoryTokenStore(old)
        let auth = session(transport, store)

        await #expect(throws: SignInError.offline) { try await auth.tokenAfterRejecting("a1") }
        #expect(store.load() == old)
    }

    @Test func aServerErrorOnRefreshKeepsTheTokens() async {
        let transport = ScriptedTransport { _ in (.internalServerError, problem(500)) }
        let store = MemoryTokenStore(old)

        await #expect(throws: SignInError.server) { try await session(transport, store).tokenAfterRejecting("a1") }
        #expect(store.load() == old)
    }

    @Test func aFailedKeychainSaveLeavesNoUsedRefreshTokenBehind() async throws {
        // The old refresh token no longer works; on the next launch it would be reused and revoke every token.
        final class FailingStore: TokenStoring, @unchecked Sendable {
            let inner = MemoryTokenStore(old)
            func load() -> StoredTokens? { inner.load() }
            func save(_ tokens: StoredTokens) throws { throw KeychainError(status: -25300) }
            func clear() { inner.clear() }
        }
        let store = FailingStore()
        let auth = session(ScriptedTransport { _ in (.ok, pair("a2", "r2")) }, store)

        #expect(try await auth.tokenAfterRejecting("a1") == "a2", "this run keeps working from memory")
        #expect(store.load() == nil)
    }

    @Test func aMalformedRefreshAnswerIsAServerError() async {
        let transport = ScriptedTransport { _ in (.ok, #"{"accessToken":"a2"}"#) }
        await #expect(throws: SignInError.server) { try await session(transport, MemoryTokenStore(old)).tokenAfterRejecting("a1") }
    }

    @Test func aSignInDuringARefreshIsNotUndone() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let transport = ScriptedTransport { operation in
            if operation == "refreshToken" {
                for await _ in gate.stream { break }
                return (.unauthorized, problem(401))
            }
            return (.ok, pair("b1", "s1"))
        }
        let store = MemoryTokenStore(old)
        let auth = session(transport, store)

        async let refreshed = auth.tokenAfterRejecting("a1")
        while !transport.operations.contains("refreshToken") { await Task.yield() }
        try await auth.verify(email: "runner@example.com", code: "123456")
        gate.continuation.yield()

        #expect(try await refreshed == "b1")
        #expect(store.load()?.refreshToken == "s1", "the refused old refresh token must not sign out the new session")
    }

    @Test func signedOutHasNothingToRefresh() async throws {
        let transport = ScriptedTransport { _ in (.ok, pair("a2", "r2")) }
        #expect(try await session(transport, MemoryTokenStore()).tokenAfterRejecting("a1") == nil)
        #expect(transport.operations.isEmpty)
    }
}
