import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

/// Answers by operation, and records the paths it was asked for.
private final class RouteTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private let routes: [String: (HTTPResponse.Status, String)]
    private let error: Error?

    init(_ routes: [String: (HTTPResponse.Status, String)], error: Error? = nil) {
        self.routes = routes
        self.error = error
    }

    var paths: [String] { lock.withLock { seen } }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { seen.append(request.path ?? "") }
        if let error { throw error }
        let (status, json) = routes[operationID] ?? (.notFound, #"{"type":"about:blank","title":"No","status":404}"#)
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = status.code < 400 ? "application/json" : "application/problem+json"
        if operationID == "getPlan", status == .ok { response.headerFields[.eTag] = #""3""# }
        return (response, HTTPBody(json))
    }
}

private func summary(_ id: String, updatedAt: String, start: String = "2026-10-05") -> String {
    #"{"id":"\#(id)","revision":1,"updatedAt":"\#(updatedAt)","deletedAt":null,"goal":{"type":"10k"},"startDate":"\#(start)","weekCount":10,"source":"rules","adaptive":true}"#
}

private let older = "11111111-1111-4111-8111-111111111111"
private let newer = PlanFixture.planID
private let problem401 = (HTTPResponse.Status.unauthorized, #"{"type":"about:blank","title":"No","status":401}"#)

struct PlanLoaderTests {
    private func loader(_ transport: RouteTransport) -> APIPlanLoader {
        APIPlanLoader(client: APIConfiguration.client(serverURL: URL(string: "http://127.0.0.1:8790")!, transport: transport))
    }

    @Test(arguments: [true, false])
    func theActivePlanIsTheMostRecentlyUpdatedOne(newerFirst: Bool) async throws {
        // The list is ordered by start date (then id), not by when a plan was saved; the latest save wins either way.
        let pair = [summary(older, updatedAt: "2026-10-27T09:00:00.000Z"), summary(newer, updatedAt: "2026-10-28T07:42:00.000Z")]
        let list = #"{"plans":[\#((newerFirst ? pair.reversed() : pair).joined(separator: ","))]}"#
        let transport = RouteTransport(["listPlans": (.ok, list), "getPlan": (.ok, String(decoding: PlanFixture.json(), as: UTF8.self))])

        let plan = try await loader(transport).activePlan()

        #expect(plan?.value1.value1.id == newer)
        #expect(transport.paths.last == "/v1/plans/\(newer)")
    }

    @Test func noPlansIsNil() async throws {
        let transport = RouteTransport(["listPlans": (.ok, #"{"plans":[]}"#)])
        #expect(try await loader(transport).activePlan() == nil)
        #expect(transport.paths.count == 1)
    }

    @Test func aPlanDeletedMeanwhileIsNil() async throws {
        let transport = RouteTransport(["listPlans": (.ok, #"{"plans":[\#(summary(newer, updatedAt: "2026-10-28T07:42:00.000Z"))]}"#)])
        #expect(try await loader(transport).activePlan() == nil)
    }

    @Test func aPlanCanBeLoadedById() async throws {
        let transport = RouteTransport(["getPlan": (.ok, String(decoding: PlanFixture.json(), as: UTF8.self))])
        #expect(try await loader(transport).plan(id: newer)?.value2.sessions.count == 51)
    }

    @Test func failuresAreExplained() async throws {
        await #expect(throws: PlanLoadError.signedOut) { try await loader(RouteTransport(["listPlans": problem401])).activePlan() }
        await #expect(throws: PlanLoadError.offline) {
            try await loader(RouteTransport([:], error: URLError(.notConnectedToInternet))).activePlan()
        }
        await #expect(throws: PlanLoadError.server) {
            try await loader(RouteTransport(["listPlans": (.internalServerError, #"{"type":"about:blank","title":"No","status":500}"#)])).activePlan()
        }
    }
}

private actor FakeLoader: PlanLoading {
    private(set) var calls: [String] = []
    let active: Result<Components.Schemas.PlanDetail?, PlanLoadError>

    init(_ active: Result<Components.Schemas.PlanDetail?, PlanLoadError>) { self.active = active }

    func activePlan() async throws -> Components.Schemas.PlanDetail? {
        calls.append("active")
        return try active.get()
    }

    func plan(id: String) async throws -> Components.Schemas.PlanDetail? {
        calls.append("plan \(id)")
        return try PlanFixture.detail(id: id)
    }
}

private actor Account: SignInService {
    let isSignedIn: Bool
    init(_ signedIn: Bool) { isSignedIn = signedIn }
    func startEmailSignIn(email: String) async throws {}
    func verify(email: String, code: String) async throws {}
}

@MainActor
struct PlanStoreTests {
    @Test func signedOutShowsTheEmptyStateWithoutAsking() async throws {
        let loader = FakeLoader(.success(try PlanFixture.detail()))
        let store = PlanStore(loader: loader, account: Account(false), writer: FakeWriter())
        await store.load()
        #expect(store.state == .empty)
        #expect(await loader.calls.isEmpty)
    }

    @Test func signedInLoadsTheActivePlan() async throws {
        let plan = try PlanFixture.detail()
        let store = PlanStore(loader: FakeLoader(.success(plan)), account: Account(true), writer: FakeWriter())
        #expect(store.state == .loading)
        await store.load()
        #expect(store.state == .loaded(plan))
    }

    @Test(arguments: [Result<Components.Schemas.PlanDetail?, PlanLoadError>.success(nil), .failure(.signedOut)])
    func noPlanOrTokensTheServerRejectsShowTheEmptyState(result: Result<Components.Schemas.PlanDetail?, PlanLoadError>) async {
        let store = PlanStore(loader: FakeLoader(result), account: Account(true), writer: FakeWriter())
        await store.load()
        #expect(store.state == .empty)
    }

    @Test func aFailureCanBeRetried() async throws {
        let store = PlanStore(loader: FakeLoader(.failure(.offline)), account: Account(true), writer: FakeWriter())
        await store.load()
        guard case .failed(let message) = store.state else { Issue.record("expected a failure, got \(store.state)"); return }
        #expect(message.contains("connection"))
    }

    @Test func aJustSavedPlanIsLoadedById() async throws {
        let loader = FakeLoader(.success(nil))
        let store = PlanStore(loader: loader, account: Account(true), writer: FakeWriter())
        await store.show(planId: "22222222-2222-4222-8222-222222222222")
        #expect(await loader.calls == ["plan 22222222-2222-4222-8222-222222222222"])
        guard case .loaded(let plan) = store.state else { Issue.record("not loaded: \(store.state)"); return }
        #expect(plan.value1.value1.id == "22222222-2222-4222-8222-222222222222")
    }
}

/// Answers session writes from a script, and records them.
actor FakeWriter: SessionWriting {
    private(set) var calls: [String] = []
    var answer: Result<String, SessionWriteError> = .success(writeResultJSON())

    init(_ answer: Result<String, SessionWriteError> = .success(writeResultJSON())) { self.answer = answer }

    private func result() throws -> Components.Schemas.SessionWriteResult {
        try APIConfiguration.decoder.decode(Components.Schemas.SessionWriteResult.self, from: Data(answer.get().utf8))
    }

    func update(id: String, revision: Int, _ body: Components.Schemas.SessionUpdate) async throws -> Components.Schemas.SessionWriteResult {
        calls.append("update \(id) @\(revision)")
        return try result()
    }

    func create(planId: String, _ body: Components.Schemas.SessionCreate) async throws -> Components.Schemas.SessionWriteResult {
        calls.append("create \(body.value2.id)")
        return try result()
    }

    func delete(id: String, revision: Int) async throws -> Components.Schemas.SessionWriteResult {
        calls.append("delete \(id) @\(revision)")
        return try result()
    }

    func checkIn(sessionId: String, feeling: BeforeFeeling, id: String) async throws {
        calls.append("checkin \(sessionId) \(feeling.feel) \(id)")
        _ = try answer.get()
    }

    func deletePlan(id: String, revision: Int) async throws {
        calls.append("deletePlan \(id) @\(revision)")
        _ = try answer.get()
    }
}

@MainActor
struct PlanStoreDeleteTests {
    private func loaded(_ writer: FakeWriter, loader: FakeLoader? = nil) async throws -> PlanStore {
        let fallback = FakeLoader(.success(try PlanFixture.detail()))
        let store = PlanStore(loader: loader ?? fallback, account: Account(true), writer: writer)
        await store.load()
        return store
    }

    @Test func deletingThePlanSendsItsRevisionAndShowsTheEmptyState() async throws {
        let writer = FakeWriter()
        let store = try await loaded(writer)
        #expect(await store.deletePlan() == nil)
        #expect(store.state == .empty)
        #expect(await writer.calls == ["deletePlan \(PlanFixture.planID) @3"])
    }

    @Test func aPlanAlreadyGoneIsTreatedAsDeleted() async throws {
        let store = try await loaded(FakeWriter(.failure(.notFound)))
        #expect(await store.deletePlan() == nil)
        #expect(store.state == .empty)
    }

    @Test func offlineKeepsThePlanAndExplains() async throws {
        let store = try await loaded(FakeWriter(.failure(.offline)))
        let error = await store.deletePlan()
        #expect(error?.contains("connection") == true)
        #expect(store.plan != nil)
    }

    @Test func aConflictReloadsThePlanAndSaysSo() async throws {
        let loader = FakeLoader(.success(try PlanFixture.detail()))
        let store = try await loaded(FakeWriter(.failure(.conflict)), loader: loader)
        let error = await store.deletePlan()
        #expect(error?.contains("changed") == true)
        #expect(store.plan != nil)
        #expect(await loader.calls == ["active", "plan \(PlanFixture.planID)"])
    }

    @Test func nothingLoadedMeansNothingToDelete() async {
        let store = PlanStore(loader: FakeLoader(.success(nil)), account: Account(false), writer: FakeWriter())
        await store.load()
        #expect(await store.deletePlan() != nil)
    }
}

@MainActor
struct PlanStoreEditTests {
    private let intervals = "00000000-0000-4000-8000-000000000017"

    private func loaded(_ writer: FakeWriter, loader: FakeLoader? = nil) async throws -> PlanStore {
        let fallback = FakeLoader(.success(try PlanFixture.detail()))
        let store = PlanStore(loader: loader ?? fallback, account: Account(true), writer: writer)
        await store.load()
        return store
    }

    private func session(_ store: PlanStore, _ id: String) -> Components.Schemas.Session? {
        store.plan?.value2.sessions.first { $0.value1.id == id }
    }

    @Test func anEditReplacesTheSessionWithTheServersCopy() async throws {
        let writer = FakeWriter(.success(writeResultJSON(title: "Mine", revision: 2)))
        let store = try await loaded(writer)
        let error = await store.apply([SessionEdit(sessionId: intervals, revision: 1, update: .init(title: "Mine"))])
        #expect(error == nil)
        #expect(session(store, intervals)?.value2.title == "Mine")
        #expect(session(store, intervals)?.value1.revision == 2, "the next edit must send the new revision")
        #expect(session(store, intervals)?.value2.owner == .user)
        #expect(store.plan?.value1.value3.contentRevision == 4)
        #expect(store.plan?.value2.warnings.map(\.code) == ["no_rest_day"])
        #expect(store.plan?.value2.sessions.count == 51)
        #expect(await writer.calls == ["update \(intervals) @1"])
    }

    @Test func aNewSessionIsAddedAndADeletedOneLeavesTheSchedule() async throws {
        let store = try await loaded(FakeWriter(.success(writeResultJSON(deleted: true))))
        #expect(await store.delete(sessionId: intervals, revision: 1) == nil)
        let schedule = PlanSchedule(plan: try #require(store.plan), today: PlanFixture.today)
        #expect(!schedule.sessions.contains { $0.value1.id == intervals })

        let fresh = try await loaded(FakeWriter(.success(writeResultJSON().replacingOccurrences(of: intervals, with: "33333333-3333-4333-8333-333333333333"))))
        #expect(await fresh.create(SessionDraft.new(date: "2026-10-29").create(id: "33333333-3333-4333-8333-333333333333")) == nil)
        #expect(fresh.plan?.value2.sessions.count == 52)
    }

    @Test func aConflictReloadsThePlanAndSaysSo() async throws {
        let loader = FakeLoader(.success(try PlanFixture.detail()))
        let store = try await loaded(FakeWriter(.failure(.conflict)), loader: loader)
        let error = await store.apply([SessionEdit(sessionId: intervals, revision: 1, update: .init(title: "Mine"))])
        #expect(error?.contains("changed") == true)
        #expect(await loader.calls == ["active", "plan \(PlanFixture.planID)"])
        #expect(session(store, intervals)?.value2.title == "Intervals: 5 × 600 m")
    }

    @Test func offlineKeepsThePlanAndExplains() async throws {
        let store = try await loaded(FakeWriter(.failure(.offline)))
        let error = await store.apply([SessionEdit(sessionId: intervals, revision: 1, update: .init(title: "Mine"))])
        #expect(error?.contains("connection") == true)
        #expect(session(store, intervals)?.value2.title == "Intervals: 5 × 600 m")
    }

    @Test func aBeforeSessionCheckInIsSent() async throws {
        let writer = FakeWriter()
        let store = try await loaded(writer)
        #expect(await store.checkIn(sessionId: intervals, feeling: .tired, id: "55555555-5555-4555-8555-555555555555") == nil)
        #expect(await writer.calls.first == "checkin \(intervals) 2 55555555-5555-4555-8555-555555555555")
    }

    @Test func aRefusedCheckInDoesNotTalkAboutSteps() async throws {
        let store = try await loaded(FakeWriter(.failure(.invalid)))
        let error = await store.checkIn(sessionId: intervals, feeling: .fresh, id: "55555555-5555-4555-8555-555555555555")
        #expect(error?.contains("check-in") == true)
    }
}
