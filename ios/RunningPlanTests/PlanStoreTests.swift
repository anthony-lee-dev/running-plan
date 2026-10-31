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
        let store = PlanStore(loader: loader, account: Account(false))
        await store.load()
        #expect(store.state == .empty)
        #expect(await loader.calls.isEmpty)
    }

    @Test func signedInLoadsTheActivePlan() async throws {
        let plan = try PlanFixture.detail()
        let store = PlanStore(loader: FakeLoader(.success(plan)), account: Account(true))
        #expect(store.state == .loading)
        await store.load()
        #expect(store.state == .loaded(plan))
    }

    @Test(arguments: [Result<Components.Schemas.PlanDetail?, PlanLoadError>.success(nil), .failure(.signedOut)])
    func noPlanOrTokensTheServerRejectsShowTheEmptyState(result: Result<Components.Schemas.PlanDetail?, PlanLoadError>) async {
        let store = PlanStore(loader: FakeLoader(result), account: Account(true))
        await store.load()
        #expect(store.state == .empty)
    }

    @Test func aFailureCanBeRetried() async throws {
        let store = PlanStore(loader: FakeLoader(.failure(.offline)), account: Account(true))
        await store.load()
        guard case .failed(let message) = store.state else { Issue.record("expected a failure, got \(store.state)"); return }
        #expect(message.contains("connection"))
    }

    @Test func aJustSavedPlanIsLoadedById() async throws {
        let loader = FakeLoader(.success(nil))
        let store = PlanStore(loader: loader, account: Account(true))
        await store.show(planId: "22222222-2222-4222-8222-222222222222")
        #expect(await loader.calls == ["plan 22222222-2222-4222-8222-222222222222"])
        guard case .loaded(let plan) = store.state else { Issue.record("not loaded: \(store.state)"); return }
        #expect(plan.value1.value1.id == "22222222-2222-4222-8222-222222222222")
    }
}
