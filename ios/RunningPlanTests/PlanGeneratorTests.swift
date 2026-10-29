import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

private final class StubTransport: ClientTransport, @unchecked Sendable {
    var lastRequest: HTTPRequest?
    var lastBody: String?
    let status: HTTPResponse.Status
    let contentType: String
    let json: String
    let error: Error?

    init(status: HTTPResponse.Status = .ok, contentType: String = "application/json", json: String, error: Error? = nil) {
        self.status = status
        self.contentType = contentType
        self.json = json
        self.error = error
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        lastRequest = request
        if let body { lastBody = try await String(collecting: body, upTo: 1_000_000) }
        if let error { throw error }
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = contentType
        return (response, HTTPBody(json))
    }
}

struct PlanGeneratorTests {
    private let deviceID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private func generator(_ transport: StubTransport) -> APIPlanGenerator {
        APIPlanGenerator(client: Client(serverURL: URL(string: "http://localhost:8787")!, transport: transport), deviceID: deviceID)
    }

    /// The JSON body the transport was sent.
    private func sentBody(_ transport: StubTransport) throws -> [String: Any] {
        let text = try #require(transport.lastBody)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func answers() -> InterviewAnswers {
        var a = InterviewAnswers()
        a.goal.distance = .halfMarathon
        a.goal.date = "2027-03-14"
        a.recentResult = .init(distanceM: 10_000, timeSec: 3300)
        a.weeklyDistanceM = 25_000
        a.runningHistory = .oneToThreeYears
        a.runsPerWeek = 4
        a.unavailableDays = [.mon, .fri]
        a.longRunDay = .sun
        a.pain = false
        a.strength = .init(enabled: true, equipment: "dumbbells")
        a.targetDisplay = .heartRate
        a.heartRate = .init(maxBpm: 188)
        return a
    }

    @Test func postsTheAnswersAndTodayToTheGenerateEndpointWithTheDeviceId() async throws {
        let transport = StubTransport(json: String(decoding: DraftFixture.json(), as: UTF8.self))
        let draft = try await generator(transport).generate(answers: answers(), today: "2026-11-02")

        #expect(transport.lastRequest?.path == "/v1/plans/generate")
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.headerFields[HTTPField.Name("X-Device-Id")!] == "11111111-2222-4333-8444-555555555555")
        let sent = try sentBody(transport)
        #expect(sent["today"] as? String == "2026-11-02")
        let sentAnswers = try #require(sent["answers"] as? [String: Any])
        #expect((sentAnswers["goal"] as? [String: Any])?["distance"] as? String == "half_marathon")
        #expect(sentAnswers["runsPerWeek"] as? Int == 4)
        #expect(sentAnswers["unavailableDays"] as? [String] == ["mon", "fri"])
        #expect((sentAnswers["heartRate"] as? [String: Any])?["maxBpm"] as? Int == 188)
        #expect(draft.weekCount == 10)
    }

    @Test func sendsOnlyWhatTheUserAnswered() async throws {
        let transport = StubTransport(json: String(decoding: DraftFixture.json(), as: UTF8.self))
        _ = try await generator(transport).generate(answers: InterviewAnswers(), today: "2026-11-02")
        let sent = try sentBody(transport)
        let sentAnswers = try #require(sent["answers"] as? [String: Any])
        #expect(Set(sentAnswers.keys) == ["goal"])
    }

    @Test(arguments: [
        (HTTPResponse.Status.tooManyRequests, PreviewError.tooManyRequests),
        (HTTPResponse.Status.badRequest, PreviewError.invalidAnswers),
        (HTTPResponse.Status.contentTooLarge, PreviewError.invalidAnswers),
        (HTTPResponse.Status.internalServerError, PreviewError.server),
    ])
    func mapsErrorStatuses(status: HTTPResponse.Status, expected: PreviewError) async {
        let transport = StubTransport(status: status, contentType: "application/problem+json", json: #"{"type":"x","title":"x","status":1}"#)
        await #expect(throws: expected) { try await generator(transport).generate(answers: answers(), today: "2026-11-02") }
    }

    @Test func aNoPlanFitsAnswerCarriesTheServersExplanation() async {
        let transport = StubTransport(status: .unprocessableContent, contentType: "application/problem+json", json: #"{"type":"goal_date_too_soon","title":"Your goal date is too soon for a 10K plan.","status":422}"#)
        await #expect(throws: PreviewError.noPlanFits("Your goal date is too soon for a 10K plan.")) {
            try await generator(transport).generate(answers: answers(), today: "2026-11-02")
        }
    }

    @Test func noNetworkIsOffline() async {
        let transport = StubTransport(json: "{}", error: URLError(.notConnectedToInternet))
        await #expect(throws: PreviewError.offline) { try await generator(transport).generate(answers: answers(), today: "2026-11-02") }
    }

    @Test func anyOtherClientFailureIsTheServers() async {
        struct Odd: Error {}
        let transport = StubTransport(json: "{}", error: Odd())
        await #expect(throws: PreviewError.server) { try await generator(transport).generate(answers: answers(), today: "2026-11-02") }
    }

    @Test func anUnreadableResponseIsTheServers() async {
        let transport = StubTransport(json: #"{"not":"a plan"}"#)
        await #expect(throws: (any Error).self) { try await generator(transport).generate(answers: answers(), today: "2026-11-02") }
    }

    @Test func cancellationIsPassedOnNotShownAsAnError() async {
        let transport = StubTransport(json: "{}", error: CancellationError())
        await #expect(throws: CancellationError.self) { try await generator(transport).generate(answers: answers(), today: "2026-11-02") }
    }

    @Test func theDeviceIdIsCreatedOnceAndKept() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let first = DeviceIdentity.current(defaults: defaults)
        #expect(DeviceIdentity.current(defaults: defaults) == first)
        defaults.set("not a uuid", forKey: "device.id")
        #expect(DeviceIdentity.current(defaults: defaults) != first)
    }
}

@MainActor
struct InterviewPrefillTests {
    private func everything() -> InterviewAnswers {
        var a = InterviewAnswers()
        a.goal.distance = .fiveK
        a.goal.date = "2027-01-10"
        a.goal.targetTimeSec = 1620
        a.recentResult = .init(distanceM: 5000, timeSec: 1710) // 28:30
        a.weeklyDistanceM = 20_000
        a.longestRunM = 8000
        a.runningHistory = .oneToThreeYears
        a.runsPerWeek = 4
        a.unavailableDays = [.mon]
        a.longRunDay = .sun
        a.pain = false
        a.strength = .init(enabled: true, equipment: "bodyweight")
        a.targetDisplay = .pace
        a.heartRate = .init(maxBpm: 188)
        return a
    }

    @Test func goingThroughEveryQuestionAgainChangesNothing() {
        let original = everything()
        let flow = InterviewFlow(prefilledWith: original)
        for _ in InterviewQuestion.allCases { flow.next() }
        #expect(flow.isFinished)
        #expect(flow.answers == original)
        #expect(flow.answers.recentResult?.timeSec == 1710)
    }

    @Test func changingOnlyTheDistanceKeepsTheExactTime() {
        let flow = InterviewFlow(prefilledWith: everything())
        flow.setRecentResult(distance: .tenK)
        #expect(flow.answers.recentResult == .init(distanceM: 10_000, timeSec: 1710))
        #expect(flow.recentMinutes == 28)
    }

    @Test func changeAnAnswerStartsFromWhatTheUserSaid() {
        let flow = InterviewFlow()
        flow.setDistance(.tenK)
        flow.setGoalDate("2027-01-10")
        flow.setRecentResult(distance: .fiveK, minutes: 28)
        flow.setWeeklyKm(20)
        flow.setHistory(.oneToThreeYears)
        flow.setRunsPerWeek(4)
        flow.toggleUnavailable(.mon)
        flow.setLongRunDay(.sun)
        flow.setPain(false)
        flow.setStrength(.dumbbells)
        flow.setTargetDisplay(.heartRate)
        flow.setMaxHeartRate(185)

        let again = InterviewFlow(prefilledWith: flow.answers)
        #expect(again.answers == flow.answers)
        for question in [InterviewQuestion.goalDistance, .goalDateAndTime, .recentResult, .weeklyDistance, .history, .runsAndDays, .longRunDay, .pain, .strength, .targetDisplay, .heartRate] {
            #expect(again.isAnswered(question), "\(question) should be answered")
        }
        #expect(!again.isAnswered(.longestRun))
        #expect(again.recentDistance == .fiveK)
        #expect(again.recentMinutes == 28)
        #expect(again.question == .goalDistance)
    }
}
