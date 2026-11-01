import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// Answers every request with a canned result, and counts what it was asked.
private actor StubGenerator: PlanGenerating {
    private(set) var calls: [InterviewAnswers] = []
    private(set) var todays: [String] = []
    var result: Result<Components.Schemas.PlanDraft, Error>

    init(_ result: Result<Components.Schemas.PlanDraft, Error>) {
        self.result = result
    }

    func generate(answers: InterviewAnswers, today: String) async throws -> Components.Schemas.PlanDraft {
        calls.append(answers)
        todays.append(today)
        return try result.get()
    }

    func set(_ new: Result<Components.Schemas.PlanDraft, Error>) {
        result = new
    }
}

private final class MemoryStore: PreviewDraftStoring {
    var saved: SavedPreview?
    func save(_ preview: SavedPreview) {
        saved = preview
    }
    func load(now: Date) -> SavedPreview? {
        guard let saved, now.timeIntervalSince(saved.savedAt) < PreviewDraftStore.lifetime else { return nil }
        return saved
    }
    func clear() { saved = nil }
}

/// The first request waits at a gate; the second answers at once. Lets a test finish them in the wrong order.
private final class GatedGenerator: PlanGenerating, @unchecked Sendable {
    private let slow: Components.Schemas.PlanDraft
    private let fast: Components.Schemas.PlanDraft
    private let lock = NSLock()
    private var calls = 0
    private var gate: CheckedContinuation<Void, Never>?

    init(slow: Components.Schemas.PlanDraft, fast: Components.Schemas.PlanDraft) {
        self.slow = slow
        self.fast = fast
    }

    var started: Int { lock.withLock { calls } }

    func generate(answers: InterviewAnswers, today: String) async throws -> Components.Schemas.PlanDraft {
        let number = lock.withLock { () -> Int in calls += 1; return calls }
        if number == 1 {
            await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
            return slow
        }
        return fast
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }
        continuation?.resume()
    }
}

@MainActor
struct PreviewViewModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func answers(runs: Int = 4) -> InterviewAnswers {
        var a = InterviewAnswers()
        a.goal.distance = .tenK
        a.runsPerWeek = runs
        return a
    }

    private func model(_ generator: StubGenerator, store: MemoryStore = MemoryStore(), answers: InterviewAnswers? = nil, at date: Date? = nil) -> PreviewViewModel {
        let moment = date ?? now
        return PreviewViewModel(answers: answers ?? self.answers(), generator: generator, store: store, now: { moment }, today: { "2026-11-02" })
    }

    @Test func startsLoading() async throws {
        #expect(model(StubGenerator(.success(try DraftFixture.draft()))).state == .loading)
    }

    @Test func generatesWhenNothingIsSavedAndKeepsTheResult() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let store = MemoryStore()
        let vm = model(generator, store: store)
        await vm.load()
        guard case .loaded(let preview) = vm.state else { Issue.record("not loaded: \(vm.state)"); return }
        #expect(preview.headline.hasPrefix("10K"))
        #expect(await generator.calls == [answers()])
        #expect(await generator.todays == ["2026-11-02"])
        #expect(store.saved?.answers == answers())
        #expect(store.saved?.savedAt == now)
    }

    @Test func usesTheSavedDraftWithoutCallingTheServer() async throws {
        let generator = StubGenerator(.failure(PreviewError.server))
        let store = MemoryStore()
        store.save(answers: answers(), draft: try DraftFixture.draft(), now: now)
        let vm = model(generator, store: store, at: now.addingTimeInterval(3600))
        await vm.load()
        guard case .loaded = vm.state else { Issue.record("not loaded: \(vm.state)"); return }
        #expect(await generator.calls.isEmpty)
    }

    @Test func theShownPreviewCarriesTheStoredIdsSoASaveCanBeRepeated() async throws {
        let store = MemoryStore()
        let generated = model(StubGenerator(.success(try DraftFixture.draft())), store: store)
        #expect(generated.current == nil)
        await generated.load()
        #expect(generated.current == store.saved)

        let reopened = model(StubGenerator(.failure(PreviewError.server)), store: store, at: now.addingTimeInterval(3600))
        await reopened.load()
        #expect(reopened.current?.ids == store.saved?.ids)
    }

    @Test func asksAgainWhenTheSavedDraftIsOlderThanADay() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let store = MemoryStore()
        store.save(answers: answers(), draft: try DraftFixture.draft(), now: now)
        await model(generator, store: store, at: now.addingTimeInterval(25 * 3600)).load()
        #expect(await generator.calls.count == 1)
    }

    @Test func asksAgainWhenTheSavedDraftIsForOtherAnswers() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let store = MemoryStore()
        store.save(answers: answers(runs: 3), draft: try DraftFixture.draft(), now: now)
        await model(generator, store: store).load()
        #expect(await generator.calls == [answers()])
    }

    @Test func startsTodayByDefault() async throws {
        let vm = model(StubGenerator(.success(try DraftFixture.draft())))
        #expect(vm.startDate == nil)
        #expect(vm.effectiveStart == "2026-11-02")
    }

    @Test func choosingAPastStartDateRegeneratesFromThatDateAndKeepsItWithTheDraft() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let store = MemoryStore()
        let vm = model(generator, store: store)
        await vm.load()
        await vm.setStartDate("2026-10-26")
        #expect(await generator.todays == ["2026-11-02", "2026-10-26"])
        #expect(vm.effectiveStart == "2026-10-26")
        #expect(store.saved?.startDate == "2026-10-26")
    }

    @Test func choosingAFutureStartDateRegeneratesFromThatDateAndKeepsItWithTheDraft() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let store = MemoryStore()
        let vm = model(generator, store: store)
        await vm.load()
        await vm.setStartDate("2026-11-09")
        #expect(await generator.todays == ["2026-11-02", "2026-11-09"])
        #expect(vm.effectiveStart == "2026-11-09")
        #expect(store.saved?.startDate == "2026-11-09")
    }

    @Test func theLatestStartIsTwelveMonthsAheadAndLaterDatesAreRefused() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let vm = model(generator)
        await vm.load()
        #expect(vm.latestStart == "2027-11-02")
        await vm.setStartDate("2027-11-03")
        #expect(await generator.calls.count == 1)
        #expect(vm.startDate == nil)
        await vm.setStartDate("2027-11-02")
        #expect(vm.startDate == "2027-11-02")
    }

    @Test func aLeapDayCapFallsBackToTheTwentyEighth() {
        #expect(PreviewViewModel.oneYearAfter("2027-02-28") == "2028-02-28")
        #expect(PreviewViewModel.oneYearAfter("2028-02-29") == "2029-02-28")
    }

    @Test func choosingTodayAgainGoesBackToTheDefault() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let vm = model(generator)
        await vm.load()
        await vm.setStartDate("2026-10-26")
        await vm.setStartDate("2026-11-02")
        #expect(vm.startDate == nil)
    }

    @Test func asksAgainWhenTheSavedDraftIsForAnotherStartDate() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let store = MemoryStore()
        store.save(SavedPreview(answers: answers(), draft: try DraftFixture.draft(), savedAt: now, startDate: "2026-10-26"))
        await model(generator, store: store).load()
        #expect(await generator.calls.count == 1)
    }

    @Test func reopeningWithTheSameStartDateUsesTheSavedDraft() async throws {
        let generator = StubGenerator(.failure(PreviewError.server))
        let store = MemoryStore()
        store.save(SavedPreview(answers: answers(), draft: try DraftFixture.draft(), savedAt: now, startDate: "2026-10-26"))
        let vm = PreviewViewModel(answers: answers(), startDate: "2026-10-26", generator: generator, store: store, now: { self.now }, today: { "2026-11-02" })
        await vm.load()
        guard case .loaded = vm.state else { Issue.record("not loaded: \(vm.state)"); return }
        #expect(await generator.calls.isEmpty)
    }

    @Test func changingAnAnswerRegeneratesAndReplacesTheSavedDraft() async throws {
        let generator = StubGenerator(.success(try DraftFixture.draft()))
        let store = MemoryStore()
        let vm = model(generator, store: store)
        await vm.load()
        await vm.regenerate(with: answers(runs: 5))
        #expect(await generator.calls == [answers(), answers(runs: 5)])
        #expect(vm.answers.runsPerWeek == 5)
        #expect(store.saved?.answers.runsPerWeek == 5)
    }

    @Test(arguments: [
        (PreviewError.tooManyRequests, "Too many tries"),
        (PreviewError.offline, "couldn't reach the server"),
        (PreviewError.invalidAnswers, "answers don't look right"),
        (PreviewError.noPlanFits("Try a later goal date."), "Try a later goal date."),
        (PreviewError.server, "Something went wrong"),
    ])
    func explainsAFailureAndDoesNotSaveAnything(error: PreviewError, text: String) async throws {
        let store = MemoryStore()
        let vm = model(StubGenerator(.failure(error)), store: store)
        await vm.load()
        guard case .failed(let message) = vm.state else { Issue.record("not failed: \(vm.state)"); return }
        #expect(message.contains(text))
        #expect(store.saved == nil)
    }

    @Test func anUnexpectedErrorGetsTheGenericMessage() async throws {
        struct Surprise: Error {}
        let vm = model(StubGenerator(.failure(Surprise())))
        await vm.load()
        #expect(vm.state == .failed("Something went wrong making your plan. Please try again."))
    }

    @Test func retryTriesAgainAfterAFailure() async throws {
        let generator = StubGenerator(.failure(PreviewError.offline))
        let vm = model(generator)
        await vm.load()
        await generator.set(.success(try DraftFixture.draft()))
        await vm.retry()
        guard case .loaded = vm.state else { Issue.record("not loaded: \(vm.state)"); return }
        #expect(await generator.calls.count == 2)
    }

    @Test func aSlowEarlierAnswerCannotOverwriteALaterOne() async throws {
        let slow = try DraftFixture.draft(weeklyKm: Array(repeating: 10, count: 10))
        let fast = try DraftFixture.draft()
        let generator = GatedGenerator(slow: slow, fast: fast)
        let vm = PreviewViewModel(answers: answers(), generator: generator, store: MemoryStore(), now: { self.now }, today: { "2026-11-02" })

        let first = Task { await vm.load() } // waits at the gate
        while generator.started < 1 { await Task.yield() }
        await vm.regenerate(with: answers(runs: 5)) // answers at once
        guard case .loaded(let shown) = vm.state else { Issue.record("not loaded: \(vm.state)"); return }
        #expect(shown == PlanPreview(draft: fast))

        generator.release() // the old request finally finishes
        await first.value
        #expect(vm.state == .loaded(PlanPreview(draft: fast)))
        #expect(vm.answers.runsPerWeek == 5)
    }

    @Test func todayIsTheLocalCalendarDate() {
        #expect(PreviewViewModel.localToday().range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
    }
}
