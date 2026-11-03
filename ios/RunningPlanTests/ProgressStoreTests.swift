import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

/// Answers every request with one reply, and records the paths and queries it was asked for.
private final class OneReplyTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private let status: HTTPResponse.Status
    private let json: String
    private let error: Error?

    init(_ status: HTTPResponse.Status, _ json: String = "", error: Error? = nil) {
        self.status = status
        self.json = json
        self.error = error
    }

    var paths: [String] { lock.withLock { seen } }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { seen.append(request.path ?? "") }
        if let error { throw error }
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = status.code < 400 ? "application/json" : "application/problem+json"
        let text = status.code < 400 ? json : #"{"type":"about:blank","title":"No","status":\#(status.code)}"#
        return (response, HTTPBody(text))
    }
}

struct ProgressLoaderTests {
    private func loader(_ transport: OneReplyTransport) -> APIProgressLoader {
        APIProgressLoader(client: APIConfiguration.client(serverURL: URL(string: "http://127.0.0.1:8790")!, transport: transport))
    }

    @Test func asksForThePlansProgressOnTheLocalDay() async throws {
        let transport = OneReplyTransport(.ok, String(decoding: ProgressFixture.json(), as: UTF8.self))
        let progress = try await loader(transport).progress(planId: PlanFixture.planID, today: PlanFixture.today)
        #expect(progress?.adherence.done == 23)
        #expect(progress?.weeks.count == 10)
        #expect(transport.paths == ["/v1/plans/\(PlanFixture.planID)/progress?today=\(PlanFixture.today)"])
    }

    @Test func aPlanThatIsGoneIsNil() async throws {
        #expect(try await loader(OneReplyTransport(.notFound)).progress(planId: PlanFixture.planID, today: PlanFixture.today) == nil)
    }

    @Test func failuresAreExplained() async throws {
        await #expect(throws: PlanLoadError.signedOut) {
            try await loader(OneReplyTransport(.unauthorized)).progress(planId: PlanFixture.planID, today: PlanFixture.today)
        }
        await #expect(throws: PlanLoadError.offline) {
            try await loader(OneReplyTransport(.ok, error: URLError(.notConnectedToInternet))).progress(planId: PlanFixture.planID, today: PlanFixture.today)
        }
        await #expect(throws: PlanLoadError.server) {
            try await loader(OneReplyTransport(.internalServerError)).progress(planId: PlanFixture.planID, today: PlanFixture.today)
        }
    }
}

private final class FakeProgressLoader: ProgressLoading, @unchecked Sendable {
    var result: Result<Components.Schemas.Progress?, PlanLoadError>

    init(result: Result<Components.Schemas.Progress?, PlanLoadError>) {
        self.result = result
    }

    func progress(planId: String, today: String) async throws -> Components.Schemas.Progress? {
        try result.get()
    }
}

@MainActor
struct ProgressStoreTests {
    @Test func loadsTheProgress() async throws {
        let progress = try ProgressFixture.progress()
        let store = ProgressStore(loader: FakeProgressLoader(result: .success(progress)))
        #expect(store.state == .loading)
        await store.load(planId: PlanFixture.planID, today: PlanFixture.today)
        #expect(store.state == .loaded(progress))
    }

    @Test func failuresSaySoInASentence() async throws {
        let offline = ProgressStore(loader: FakeProgressLoader(result: .failure(.offline)))
        await offline.load(planId: PlanFixture.planID, today: PlanFixture.today)
        #expect(offline.state == .failed("We couldn't reach the server. Check your connection and try again."))

        let gone = ProgressStore(loader: FakeProgressLoader(result: .success(nil)))
        await gone.load(planId: PlanFixture.planID, today: PlanFixture.today)
        #expect(gone.state == .failed("This plan is no longer available. Pull to refresh."))

        let signedOut = ProgressStore(loader: FakeProgressLoader(result: .failure(.signedOut)))
        await signedOut.load(planId: PlanFixture.planID, today: PlanFixture.today)
        #expect(signedOut.state == .failed("You've been signed out. Sign in again to see your progress."))
    }

    @Test func aFailedRefreshKeepsWhatWasShown() async throws {
        // A refresh after an edit that fails offline should not blank the screen.
        let progress = try ProgressFixture.progress()
        let loader = FakeProgressLoader(result: .success(progress))
        let store = ProgressStore(loader: loader)
        await store.load(planId: PlanFixture.planID, today: PlanFixture.today)
        loader.result = .failure(.offline)
        await store.load(planId: PlanFixture.planID, today: PlanFixture.today)
        #expect(store.state == .loaded(progress))
    }
}
