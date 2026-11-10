import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// A scripted summary service that counts its calls.
private final class StubSummaries: RunSummaryServing, @unchecked Sendable {
    var first: Result<RunSummaryResult, Error>
    var written: Result<RunSummaryResult, Error>
    var enabled: Result<Bool, Error> = .success(true)
    var setResult: Result<Void, Error> = .success(())
    private(set) var summaryCalls = 0
    private(set) var generateCalls = 0
    private(set) var setCalls: [Bool] = []

    init(first: Result<RunSummaryResult, Error>, written: Result<RunSummaryResult, Error> = .failure(RunSummaryError.server)) {
        self.first = first
        self.written = written
    }

    func summary(activityId: String, today: String) async throws -> RunSummaryResult { summaryCalls += 1; return try first.get() }
    func generate(activityId: String, today: String) async throws -> RunSummaryResult { generateCalls += 1; return try written.get() }
    func aiEnabled() async throws -> Bool { try enabled.get() }
    func setAIEnabled(_ on: Bool) async throws { setCalls.append(on); try setResult.get() }
}

private let template = RunSummaryResult(text: "10.0 km in 58 min at 5:50/km.", nextStep: "Next planned session: Easy run, 6.0 km, on Wednesday.", isAI: false, canGenerate: true, pain: false)
private let ai = RunSummaryResult(text: "A steady 10.0 km in 58 min.", nextStep: "Next planned session: Easy run, 6.0 km, on Wednesday.", isAI: true, canGenerate: false, pain: false)

@MainActor
struct RunSummaryStoreTests {
    @Test func showsTheTemplateThenSwapsInTheAIText() async {
        let service = StubSummaries(first: .success(template), written: .success(ai))
        let store = RunSummaryStore(service: service)
        await store.open(activityId: "a1", today: "2026-11-02")
        #expect(store.result == ai)
        #expect(service.summaryCalls == 1)
        #expect(service.generateCalls == 1)
    }

    @Test func doesNotAskAgainWhenTheServerAlreadyHasTheTextOrCannotWrite() async {
        let stored = StubSummaries(first: .success(ai), written: .success(template))
        let store = RunSummaryStore(service: stored)
        await store.open(activityId: "a1", today: "2026-11-02")
        #expect(store.result == ai)
        #expect(stored.generateCalls == 0)
    }

    @Test(arguments: [RunSummaryError.rateLimited, .offline, .server, .signedOut, .notFound])
    func aFailureToWriteKeepsTheTemplate(error: RunSummaryError) async {
        let service = StubSummaries(first: .success(template), written: .failure(error))
        let store = RunSummaryStore(service: service)
        await store.open(activityId: "a1", today: "2026-11-02")
        #expect(store.result == template)
        #expect(service.generateCalls == 1)
    }

    @Test func showsNothingWhenTheSummaryCannotBeRead() async {
        let service = StubSummaries(first: .failure(RunSummaryError.offline))
        let store = RunSummaryStore(service: service)
        await store.open(activityId: "a1", today: "2026-11-02")
        #expect(store.result == nil)
        #expect(service.generateCalls == 0)
    }

    @Test func aPainRunKeepsItsGuidanceAndAIText() async {
        let guidance = "If something hurts, stop and talk to a qualified professional. This app can't give medical advice."
        let pain = RunSummaryResult(text: "10.0 km in 58 min.", nextStep: guidance, isAI: true, canGenerate: false, pain: true)
        let service = StubSummaries(first: .success(pain))
        let store = RunSummaryStore(service: service)
        await store.open(activityId: "a1", today: "2026-11-02")
        #expect(store.result?.nextStep == CheckInModel.guidance)
        #expect(store.result?.pain == true)
    }
}

@MainActor
struct AISummarySwitchTests {
    @Test func loadsTheServersSettingAndSavesAChange() async {
        let service = StubSummaries(first: .success(template))
        let model = AISummarySwitch(service: service)
        #expect(model.isOn == nil)
        await model.load()
        #expect(model.isOn == true)
        await model.set(false)
        #expect(model.isOn == false)
        #expect(service.setCalls == [false])
        #expect(model.error == nil)
    }

    @Test func aFailedSaveSaysSoAndShowsTheServersValue() async {
        let service = StubSummaries(first: .success(template))
        service.setResult = .failure(RunSummaryError.offline)
        service.enabled = .success(true)
        let model = AISummarySwitch(service: service)
        await model.load()
        await model.set(false)
        #expect(model.isOn == true)
        #expect(model.error != nil)
    }
}

struct RunSummaryMappingTests {
    @Test func theAPIReplyBecomesTheCardsResult() {
        let summary = Components.Schemas.RunSummary(text: "t", nextStep: "n", source: .ai, canGenerate: false, pain: true)
        #expect(APIRunSummaryService.result(summary) == RunSummaryResult(text: "t", nextStep: "n", isAI: true, canGenerate: false, pain: true))
        let plain = Components.Schemas.RunSummary(text: "t", source: .template, reason: .not_generated, canGenerate: true, pain: false)
        #expect(APIRunSummaryService.result(plain) == RunSummaryResult(text: "t", nextStep: nil, isAI: false, canGenerate: true, pain: false))
    }
}
