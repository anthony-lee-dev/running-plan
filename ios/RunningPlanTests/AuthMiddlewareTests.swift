import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

/// What the middleware passed on, one entry per attempt.
private final class Downstream: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [(auth: String?, body: String?)] = []
    private var statuses: [HTTPResponse.Status]

    init(_ statuses: [HTTPResponse.Status]) { self.statuses = statuses }

    var auths: [String?] { lock.withLock { attempts.map(\.auth) } }
    var bodies: [String?] { lock.withLock { attempts.map(\.body) } }

    func next(_ request: HTTPRequest, _ body: HTTPBody?, _ url: URL) async throws -> (HTTPResponse, HTTPBody?) {
        let text: String? = if let body { try await String(collecting: body, upTo: 100_000) } else { nil }
        let status = lock.withLock {
            attempts.append((request.headerFields[.authorization], text))
            return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        }
        return (HTTPResponse(status: status), nil)
    }
}

private let userID = "6f1c2a4e-1b7d-4c1e-9a55-2f0b8f3c9d10"

/// A session whose refresh answers with `status` (and a new pair `a2`/`r2` when that is 200).
private func session(tokens: StoredTokens?, refresh status: HTTPResponse.Status = .ok) -> (AuthSession, MemoryTokenStore) {
    struct RefreshTransport: ClientTransport {
        let status: HTTPResponse.Status
        func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
            var response = HTTPResponse(status: status)
            response.headerFields[.contentType] = status == .ok ? "application/json" : "application/problem+json"
            let json = status == .ok
                ? #"{"accessToken":"a2","refreshToken":"r2","tokenType":"Bearer","expiresIn":900,"scopes":["app"],"userId":"\#(userID)"}"#
                : #"{"type":"about:blank","title":"No","status":\#(status.code)}"#
            return (response, HTTPBody(json))
        }
    }
    let store = MemoryTokenStore(tokens)
    let client = Client(serverURL: URL(string: "http://127.0.0.1:8790")!, transport: RefreshTransport(status: status))
    return (AuthSession(client: client, store: store), store)
}

private let signedIn = StoredTokens(accessToken: "a1", refreshToken: "r1", userId: userID)
private let url = URL(string: "http://127.0.0.1:8790")!

struct AuthMiddlewareTests {
    private func call(_ middleware: AuthMiddleware, _ downstream: Downstream, operation: String, body: String? = nil) async throws -> HTTPResponse.Status {
        let (response, _) = try await middleware.intercept(
            HTTPRequest(method: .post, scheme: "http", authority: "127.0.0.1:8790", path: "/v1/plans"),
            body: body.map { HTTPBody($0) },
            baseURL: url,
            operationID: operation,
            next: downstream.next
        )
        return response.status
    }

    @Test(arguments: ["getHealth", "startEmailSignIn", "verifyEmailSignIn", "refreshToken", "generatePlan"])
    func publicOperationsCarryNoToken(operation: String) async throws {
        let downstream = Downstream([.ok])
        _ = try await call(AuthMiddleware(session: session(tokens: signedIn).0), downstream, operation: operation)
        #expect(downstream.auths == [nil])
    }

    @Test func signedInOperationsCarryTheBearerToken() async throws {
        let downstream = Downstream([.created])
        let status = try await call(AuthMiddleware(session: session(tokens: signedIn).0), downstream, operation: "createPlan")
        #expect(status == .created)
        #expect(downstream.auths == ["Bearer a1"])
    }

    @Test func a401RefreshesAndRetriesOnceWithTheSameBody() async throws {
        let (auth, store) = session(tokens: signedIn)
        let downstream = Downstream([.unauthorized, .created])

        let status = try await call(AuthMiddleware(session: auth), downstream, operation: "createPlan", body: #"{"id":"p"}"#)

        #expect(status == .created)
        #expect(downstream.auths == ["Bearer a1", "Bearer a2"])
        #expect(downstream.bodies == [#"{"id":"p"}"#, #"{"id":"p"}"#])
        #expect(store.load()?.accessToken == "a2")
    }

    @Test func aSecond401IsReturnedNotRetriedAgain() async throws {
        let downstream = Downstream([.unauthorized])
        let status = try await call(AuthMiddleware(session: session(tokens: signedIn).0), downstream, operation: "createPlan")
        #expect(status == .unauthorized)
        #expect(downstream.auths.count == 2)
    }

    @Test func aRefusedRefreshReturnsThe401AndSignsOut() async throws {
        let (auth, store) = session(tokens: signedIn, refresh: .unauthorized)
        let downstream = Downstream([.unauthorized])

        let status = try await call(AuthMiddleware(session: auth), downstream, operation: "createPlan")

        #expect(status == .unauthorized)
        #expect(downstream.auths == ["Bearer a1"])
        #expect(store.load() == nil)
    }

    @Test func aServerErrorOnRefreshThrowsAndKeepsTheTokens() async throws {
        let (auth, store) = session(tokens: signedIn, refresh: .internalServerError)
        let downstream = Downstream([.unauthorized])

        await #expect(throws: SignInError.server) { try await call(AuthMiddleware(session: auth), downstream, operation: "createPlan") }
        #expect(store.load() == signedIn)
    }

    @Test func signedOutSendsNoTokenSoTheServerAnswers401() async throws {
        let downstream = Downstream([.unauthorized])
        let status = try await call(AuthMiddleware(session: session(tokens: nil).0), downstream, operation: "createPlan")
        #expect(status == .unauthorized)
        #expect(downstream.auths == [nil])
    }
}
