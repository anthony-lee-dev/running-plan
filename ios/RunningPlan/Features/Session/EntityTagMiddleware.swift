import Foundation
import HTTPTypes
import OpenAPIRuntime

/// The OpenAPI runtime percent-encodes header parameters, so `If-Match: "3"` would go out as `%223%22`, which the API
/// refuses (it reads a quoted entity tag). This puts the quotes back just before the request is sent.
struct EntityTagMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let value = request.headerFields[.ifMatch], let decoded = value.removingPercentEncoding {
            request.headerFields[.ifMatch] = decoded
        }
        return try await next(request, body, baseURL)
    }
}
