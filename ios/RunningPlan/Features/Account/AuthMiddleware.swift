import APIClient
import Foundation
import HTTPTypes

/// Adds the bearer token to every operation that needs one. On a 401 it gets a fresh token from the session (which
/// refreshes at most once at a time) and retries once; if the session is signed out the 401 goes back to the caller.
struct AuthMiddleware: ClientMiddleware {
    let session: AuthSession

    /// Operations the spec marks as needing no token.
    static let publicOperations: Set<String> = ["getHealth", "startEmailSignIn", "verifyEmailSignIn", "refreshToken", "generatePlan"]
    /// Request bodies are read once so a retry can send them again. Plans are capped well below this.
    static let maxBody = 4 * 1024 * 1024

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if Self.publicOperations.contains(operationID) { return try await next(request, body, baseURL) }
        guard let token = await session.accessToken() else { return try await next(request, body, baseURL) }

        let data: Data? = if let body { try await Data(collecting: body, upTo: Self.maxBody) } else { nil }
        let first = try await next(Self.authorized(request, token), data.map { HTTPBody($0) }, baseURL)
        guard first.0.status == .unauthorized, let fresh = try await session.tokenAfterRejecting(token) else { return first }
        return try await next(Self.authorized(request, fresh), data.map { HTTPBody($0) }, baseURL)
    }

    private static func authorized(_ request: HTTPRequest, _ token: String) -> HTTPRequest {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        return request
    }
}
