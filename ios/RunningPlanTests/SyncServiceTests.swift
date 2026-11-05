import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

/// Answers every call with one status and body, and keeps the last request body.
private final class OneAnswer: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var lastBody: String?
    let status: HTTPResponse.Status
    let json: String
    let error: Error?

    init(_ status: HTTPResponse.Status, _ json: String = #"{"results":[],"changes":{"plans":[],"sessions":[],"checkins":[],"proposals":[]},"cursor":"c","hasMore":false}"#, error: Error? = nil) {
        self.status = status
        self.json = json
        self.error = error
    }

    /// The request body with keys sorted, so a test compares text.
    var body: String? {
        guard let text = lock.withLock({ lastBody }), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let text = body == nil ? nil : try await String(collecting: body!, upTo: 1 << 20)
        lock.withLock { lastBody = text }
        if let error { throw error }
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = status.code < 400 ? "application/json" : "application/problem+json"
        return (response, HTTPBody(json))
    }
}

struct SyncServiceTests {
    private func service(_ transport: OneAnswer) -> APISyncService {
        APISyncService(client: APIConfiguration.client(serverURL: URL(string: "http://127.0.0.1:8790")!, transport: transport))
    }

    private let key = "11111111-1111-4111-8111-111111111111"

    private func sent(_ op: SyncOp, cursor: String? = nil) async throws -> String? {
        let transport = OneAnswer(.ok)
        _ = try await service(transport).sync(cursor: cursor, operations: [op])
        return transport.body
    }

    @Test func aSessionUpdateGoesOutAsTheSpecDescribesIt() async throws {
        let op = SyncOp.sessionUpdate(key: key, id: syncSession, baseRevision: 3, .init(title: "Mine", clear: [.notes]))
        let body = try await sent(op, cursor: "abc")
        #expect(body == #"{"cursor":"abc","operations":[{"baseRevision":3,"data":{"clear":["notes"],"title":"Mine"},"id":"\#(syncSession)","idempotencyKey":"\#(key)","kind":"session.update"}]}"#)
    }

    @Test func aSessionDeleteCarriesNoData() async throws {
        let body = try await sent(.sessionDelete(key: key, id: syncSession, baseRevision: 2))
        #expect(body == #"{"operations":[{"baseRevision":2,"id":"\#(syncSession)","idempotencyKey":"\#(key)","kind":"session.delete"}]}"#)
    }

    @Test func aSessionCreateFlattensItsContentIntoData() async throws {
        let content = try decode(Components.Schemas.SessionContent.self, #"{"date":"2026-10-29","type":"rest","title":"Rest day","status":"planned","owner":"user"}"#)
        let op = SyncOp.sessionCreate(key: key, planId: PlanFixture.planID, .init(value1: content, value2: .init(id: otherSession)))
        let body = try await sent(op)
        #expect(body == #"{"operations":[{"data":{"date":"2026-10-29","owner":"user","status":"planned","title":"Rest day","type":"rest"},"id":"\#(otherSession)","idempotencyKey":"\#(key)","kind":"session.create","planId":"\#(PlanFixture.planID)"}]}"#)
    }

    @Test func anAfterSessionCheckInCarriesItsFields() async throws {
        let op = SyncOp.checkIn(key: key, id: otherSession, sessionId: syncSession, .after(AfterCheckIn(feeling: .harder, pain: true)))
        let body = try await sent(op)
        #expect(body == #"{"operations":[{"data":{"effortFelt":8,"feel":2,"pain":true,"when":"after"},"id":"\#(otherSession)","idempotencyKey":"\#(key)","kind":"checkin.create","sessionId":"\#(syncSession)"}]}"#)
    }

    @Test func aBeforeSessionCheckInHasNoEffort() async throws {
        let op = SyncOp.checkIn(key: key, id: otherSession, sessionId: syncSession, .before(.tired))
        let body = try await sent(op)
        #expect(body == #"{"operations":[{"data":{"feel":2,"when":"before"},"id":"\#(otherSession)","idempotencyKey":"\#(key)","kind":"checkin.create","sessionId":"\#(syncSession)"}]}"#)
    }

    @Test func theResponseIsReadWithMillisecondTimestamps() async throws {
        let json = #"{"results":[{"idempotencyKey":"\#(key)","status":"conflict","server":\#(sessionJSON())}],"changes":{"plans":[],"sessions":[\#(sessionJSON())],"checkins":[],"proposals":[]},"cursor":"c9","hasMore":true}"#
        let answer = try await service(OneAnswer(.ok, json)).sync(cursor: nil, operations: [])
        #expect(answer.cursor == "c9")
        #expect(answer.hasMore)
        #expect(answer.results.first?.server?.sessionId == syncSession)
    }

    @Test func failuresAreExplained() async throws {
        let problem = #"{"type":"about:blank","title":"No","status":400}"#
        await #expect(throws: SyncError.signedOut) { try await service(OneAnswer(.unauthorized, problem)).sync(cursor: nil, operations: []) }
        await #expect(throws: SyncError.badRequest) { try await service(OneAnswer(.badRequest, problem)).sync(cursor: nil, operations: []) }
        await #expect(throws: SyncError.tooLarge) { try await service(OneAnswer(.contentTooLarge, problem)).sync(cursor: nil, operations: []) }
        await #expect(throws: SyncError.server) { try await service(OneAnswer(.internalServerError, problem)).sync(cursor: nil, operations: []) }
        await #expect(throws: SyncError.offline) {
            try await service(OneAnswer(.ok, error: URLError(.notConnectedToInternet))).sync(cursor: nil, operations: [])
        }
    }
}
