import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

/// Answers every call with one status and body, and keeps the last request and its body.
private final class OneAnswer: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var lastRequest: HTTPRequest?
    private var lastBody: String?
    let status: HTTPResponse.Status
    let json: String
    let error: Error?

    init(_ status: HTTPResponse.Status, _ json: String = "{}", error: Error? = nil) {
        self.status = status
        self.json = json
        self.error = error
    }

    var request: HTTPRequest? { lock.withLock { lastRequest } }
    /// The request body as compact JSON (the runtime pretty-prints it).
    var body: String? {
        guard let text = lock.withLock({ lastBody }), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let text = body == nil ? nil : try await String(collecting: body!, upTo: 1 << 20)
        lock.withLock {
            lastRequest = request
            lastBody = text
        }
        if let error { throw error }
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = status.code < 400 ? "application/json" : "application/problem+json"
        return (response, HTTPBody(json))
    }
}

/// A `SessionWriteResult` for the boards' intervals session at a new revision.
func writeResultJSON(title: String = "Intervals: 5 × 600 m", revision: Int = 2, deleted: Bool = false, owner: String = "user") -> String {
    #"{"session":{"id":"00000000-0000-4000-8000-000000000017","planId":"\#(PlanFixture.planID)","revision":\#(revision),"updatedAt":"2026-10-28T08:00:00.000Z","deletedAt":\#(deleted ? #""2026-10-28T08:00:00.000Z""# : "null"),"date":"2026-10-28","type":"intervals","title":"\#(title)","status":"planned","owner":"\#(owner)","steps":[]},"planContentRevision":4,"warnings":[{"code":"no_rest_day","severity":"caution","message":"No rest day this week"}]}"#
}

private let problem = #"{"type":"about:blank","title":"No","status":409}"#

struct SessionWriterDeletePlanTests {
    private let planId = "11111111-1111-4111-8111-111111111111"

    private func writer(_ transport: OneAnswer) -> APISessionWriter {
        APISessionWriter(client: APIConfiguration.client(serverURL: URL(string: "http://127.0.0.1:8790")!, transport: transport))
    }

    @Test func deletingAPlanSendsItsRevisionAsAQuotedETag() async throws {
        let transport = OneAnswer(.noContent, "")
        try await writer(transport).deletePlan(id: planId, revision: 3)
        #expect(transport.request?.method == .delete)
        #expect(transport.request?.path == "/v1/plans/\(planId)")
        #expect(transport.request?.headerFields[.ifMatch] == "\"3\"")
    }

    @Test func deletingAPlanMapsFailures() async throws {
        await #expect(throws: SessionWriteError.conflict) { try await writer(OneAnswer(.conflict, problem)).deletePlan(id: planId, revision: 3) }
        await #expect(throws: SessionWriteError.notFound) { try await writer(OneAnswer(.notFound, problem)).deletePlan(id: planId, revision: 3) }
        await #expect(throws: SessionWriteError.signedOut) { try await writer(OneAnswer(.unauthorized, problem)).deletePlan(id: planId, revision: 3) }
        await #expect(throws: SessionWriteError.offline) {
            try await writer(OneAnswer(.ok, error: URLError(.notConnectedToInternet))).deletePlan(id: planId, revision: 3)
        }
    }
}

struct SessionWriterTests {
    private func writer(_ transport: OneAnswer) -> APISessionWriter {
        APISessionWriter(client: APIConfiguration.client(serverURL: URL(string: "http://127.0.0.1:8790")!, transport: transport))
    }

    @Test func anEditSendsTheBaseRevisionAsAQuotedETag() async throws {
        let transport = OneAnswer(.ok, writeResultJSON(title: "Mine"))
        let result = try await writer(transport).update(id: "00000000-0000-4000-8000-000000000017", revision: 1, .init(title: "Mine"))
        #expect(result.session.value2.title == "Mine")
        #expect(transport.request?.method == .patch)
        #expect(transport.request?.path == "/v1/sessions/00000000-0000-4000-8000-000000000017")
        #expect(transport.request?.headerFields[.ifMatch] == #""1""#)
        #expect(transport.body?.contains(#""title":"Mine""#) == true)
    }

    @Test func createDeleteAndCheckInUseTheirEndpoints() async throws {
        let created = OneAnswer(.created, writeResultJSON())
        _ = try await writer(created).create(planId: PlanFixture.planID, SessionDraft.new(date: "2026-10-29").create(id: "11111111-1111-4111-8111-111111111111"))
        #expect(created.request?.path == "/v1/plans/\(PlanFixture.planID)/sessions")

        let deleted = OneAnswer(.ok, writeResultJSON(deleted: true))
        let gone = try await writer(deleted).delete(id: "00000000-0000-4000-8000-000000000017", revision: 2)
        #expect(gone.session.value1.deletedAt != nil)
        #expect(deleted.request?.method == .delete)
        #expect(deleted.request?.headerFields[.ifMatch] == #""2""#)

        let checkIn = #"{"id":"22222222-2222-4222-8222-222222222222","revision":1,"updatedAt":"2026-10-28T08:00:00.000Z","deletedAt":null,"sessionId":"00000000-0000-4000-8000-000000000017","when":"before","feel":5}"#
        let checked = OneAnswer(.created, checkIn)
        try await writer(checked).checkIn(sessionId: "00000000-0000-4000-8000-000000000017", feeling: .fresh, id: "22222222-2222-4222-8222-222222222222")
        #expect(checked.request?.path == "/v1/sessions/00000000-0000-4000-8000-000000000017/checkins")
        #expect(checked.body?.contains(#""when":"before""#) == true)
        #expect(checked.body?.contains(#""feel":5"#) == true)
    }

    @Test func anAfterSessionCheckInSendsFeelEffortAndPain() async throws {
        let checkIn = #"{"id":"33333333-3333-4333-8333-333333333333","revision":1,"updatedAt":"2026-10-28T08:00:00.000Z","deletedAt":null,"sessionId":"00000000-0000-4000-8000-000000000017","when":"after","feel":2,"effortFelt":8,"pain":true}"#
        let checked = OneAnswer(.created, checkIn)
        try await writer(checked).checkIn(sessionId: "00000000-0000-4000-8000-000000000017", after: AfterCheckIn(feeling: .harder, pain: true), id: "33333333-3333-4333-8333-333333333333")
        #expect(checked.request?.path == "/v1/sessions/00000000-0000-4000-8000-000000000017/checkins")
        #expect(checked.body?.contains(#""when":"after""#) == true)
        #expect(checked.body?.contains(#""feel":2"#) == true)
        #expect(checked.body?.contains(#""effortFelt":8"#) == true)
        #expect(checked.body?.contains(#""pain":true"#) == true)
        #expect(checked.body?.contains(#""id":"33333333-3333-4333-8333-333333333333""#) == true)
    }

    @Test func failuresAreExplained() async throws {
        await #expect(throws: SessionWriteError.conflict) {
            try await writer(OneAnswer(.conflict, problem)).update(id: "00000000-0000-4000-8000-000000000017", revision: 1, .init(title: "x"))
        }
        await #expect(throws: SessionWriteError.invalid) {
            try await writer(OneAnswer(.badRequest, problem)).update(id: "00000000-0000-4000-8000-000000000017", revision: 1, .init(title: "x"))
        }
        await #expect(throws: SessionWriteError.signedOut) {
            try await writer(OneAnswer(.unauthorized, problem)).update(id: "00000000-0000-4000-8000-000000000017", revision: 1, .init(title: "x"))
        }
        await #expect(throws: SessionWriteError.notFound) {
            try await writer(OneAnswer(.notFound, problem)).delete(id: "00000000-0000-4000-8000-000000000017", revision: 1)
        }
        await #expect(throws: SessionWriteError.offline) {
            try await writer(OneAnswer(.ok, error: URLError(.notConnectedToInternet))).update(id: "00000000-0000-4000-8000-000000000017", revision: 1, .init(title: "x"))
        }
    }
}
