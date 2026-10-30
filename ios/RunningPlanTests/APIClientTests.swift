import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

/// Answers every request with a canned response and records what was asked.
private final class StubTransport: ClientTransport, @unchecked Sendable {
    var lastRequest: HTTPRequest?
    var lastBody: String?
    let status: HTTPResponse.Status
    let json: String

    init(status: HTTPResponse.Status = .ok, json: String) {
        self.status = status
        self.json = json
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lastRequest = request
        if let body { lastBody = try await String(collecting: body, upTo: 1_000_000) }
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

struct APIClientTests {
    @Test func healthCallGoesToTheSpecPathAndDecodesTheBody() async throws {
        let transport = StubTransport(json: #"{"status":"ok","storage":true,"time":"2026-10-28T12:00:00Z"}"#)
        let client = Client(serverURL: URL(string: "http://localhost:8787")!, transport: transport)

        let output = try await client.getHealth()

        #expect(transport.lastRequest?.path == "/v1/health")
        let health = try output.ok.body.json
        #expect(health.status == .ok)
        #expect(health.storage)
    }

    @Test func degradedHealthComesBackAsTheServiceUnavailableCase() async throws {
        let transport = StubTransport(
            status: .serviceUnavailable,
            json: #"{"status":"degraded","storage":false,"time":"2026-10-28T12:00:00Z"}"#
        )
        let client = Client(serverURL: URL(string: "http://localhost:8787")!, transport: transport)

        let output = try await client.getHealth()

        let health = try output.serviceUnavailable.body.json
        #expect(health.status == .degraded)
    }

    @Test func planGenerationTakesInterviewAnswers() async throws {
        let transport = StubTransport(json: "{}")
        let client = Client(serverURL: URL(string: "http://localhost:8787")!, transport: transport)
        let answers = Components.Schemas.InterviewAnswers(goal: .init(distance: ._5k))

        // The call itself is what this checks: it compiles against the generated types and posts to the spec path.
        _ = try? await client.generatePlan(body: .json(.init(answers: answers, today: "2026-10-28")))

        #expect(transport.lastRequest?.path == "/v1/plans/generate")
        #expect(transport.lastRequest?.method == .post)
        let sent = try #require(transport.lastBody)
        let object = try #require(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect(object["today"] as? String == "2026-10-28")
        #expect((object["answers"] as? [String: Any])?["goal"] != nil)
    }
}
