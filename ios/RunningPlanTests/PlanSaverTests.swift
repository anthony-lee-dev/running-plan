import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

private final class StubTransport: ClientTransport, @unchecked Sendable {
    var lastBody: String?
    var lastOperation: String?
    let status: HTTPResponse.Status
    let error: Error?

    init(status: HTTPResponse.Status = .created, error: Error? = nil) {
        self.status = status
        self.error = error
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        lastOperation = operationID
        if let body { lastBody = try await String(collecting: body, upTo: 2_000_000) }
        if let error { throw error }
        var response = HTTPResponse(status: status)
        if status.code < 300 {
            // The saver needs only the status; an echo of the sent plan stands in for the stored one.
            response.headerFields[.contentType] = "application/json"
            response.headerFields[.eTag] = #""1""#
            return (response, HTTPBody(Self.detail(from: lastBody ?? "{}")))
        }
        response.headerFields[.contentType] = "application/problem+json"
        return (response, HTTPBody(#"{"type":"about:blank","title":"No","status":\#(status.code)}"#))
    }

    /// A `PlanDetail` built from the sent `PlanCreate`.
    private static func detail(from sent: String) -> String {
        guard var plan = (try? JSONSerialization.jsonObject(with: Data(sent.utf8))) as? [String: Any] else { return "{}" }
        let sessions = (plan["sessions"] as? [[String: Any]] ?? []).map { s -> [String: Any] in
            var s = s
            s["planId"] = plan["id"]; s["revision"] = 1; s["updatedAt"] = "2026-10-30T12:00:00.041Z"; s["deletedAt"] = NSNull()
            return s
        }
        plan["sessions"] = sessions
        plan["revision"] = 1; plan["contentRevision"] = 1; plan["warnings"] = []
        plan["updatedAt"] = "2026-10-30T12:00:00.041Z"; plan["deletedAt"] = NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: plan)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

struct PlanSaverTests {
    private func preview() throws -> SavedPreview {
        var answers = InterviewAnswers()
        answers.goal.distance = .tenK
        return SavedPreview(answers: answers, draft: try DraftFixture.draft(), savedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func saver(_ transport: StubTransport) -> APIPlanSaver {
        // The app's client setup, which must read the server's timestamps (JavaScript's `toISOString`, with milliseconds).
        APIPlanSaver(client: APIConfiguration.client(serverURL: URL(string: "http://127.0.0.1:8790")!, transport: transport))
    }

    private func sent(_ transport: StubTransport) throws -> [String: Any] {
        let text = try #require(transport.lastBody)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func idsAreMadeOncePerDraftAndKeptWithIt() throws {
        let p = try preview()
        #expect(p.ids.sessions.count == p.draft.sessions.count)
        #expect(UUID(uuidString: p.ids.plan) != nil)
        #expect(p.ids.plan == p.ids.plan.lowercased())
        #expect(Set(p.ids.sessions).count == p.ids.sessions.count)
        let decoded = try JSONDecoder().decode(SavedPreview.self, from: JSONEncoder().encode(p))
        #expect(decoded.ids == p.ids)
    }

    @Test func theBodyIsThePlanFieldsWithTheStoredIdsAndNothingElse() async throws {
        // PlanCreate forbids unknown fields: a draft's assumptions and warnings must not be sent.
        let transport = StubTransport()
        let p = try preview()

        _ = try await saver(transport).save(p)

        let body = try sent(transport)
        #expect(transport.lastOperation == "createPlan")
        #expect(Set(body.keys) == ["goal", "startDate", "weekCount", "source", "engine", "adaptive", "weeks", "id", "sessions"])
        #expect(body["id"] as? String == p.ids.plan)
        let sessions = try #require(body["sessions"] as? [[String: Any]])
        #expect(sessions.map { $0["id"] as? String } == p.ids.sessions)
        #expect(sessions.first?["type"] as? String == p.draft.sessions.first?._type.rawValue)
        #expect(sessions.count == p.draft.sessions.count)
    }

    @Test(arguments: [HTTPResponse.Status.created, .ok])
    func aCreateOrAReplayReturnsThePlanId(status: HTTPResponse.Status) async throws {
        let p = try preview()
        #expect(try await saver(StubTransport(status: status)).save(p) == p.ids.plan)
    }

    @Test(arguments: [
        (HTTPResponse.Status.unauthorized, SaveError.signedOut),
        (.conflict, .conflict),
        (.badRequest, .server),
        (.contentTooLarge, .server),
        (.internalServerError, .server),
    ])
    func failuresAreExplained(status: HTTPResponse.Status, expected: SaveError) async throws {
        let p = try preview()
        await #expect(throws: expected) { try await saver(StubTransport(status: status)).save(p) }
    }

    @Test(arguments: [URLError(.notConnectedToInternet) as Error, SignInError.offline])
    func noNetworkIsOffline(error: Error) async throws {
        // `SignInError.offline` is what the auth middleware throws when it cannot refresh the token.
        let p = try preview()
        await #expect(throws: SaveError.offline) { try await saver(StubTransport(error: error)).save(p) }
    }
}
