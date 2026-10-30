import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct PreviewDraftStoreTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() -> (PreviewDraftStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return (PreviewDraftStore(defaults: defaults), defaults)
    }

    private func answers() -> InterviewAnswers {
        var a = InterviewAnswers()
        a.goal.distance = .tenK
        a.runsPerWeek = 4
        return a
    }

    @Test func keepsAPreviewForTwentyFourHours() throws {
        let (store, _) = store()
        store.save(answers: answers(), draft: try DraftFixture.draft(), now: start)
        let saved = try #require(store.load(now: start.addingTimeInterval(23 * 3600 + 59 * 60)))
        #expect(saved.answers == answers())
        #expect(saved.savedAt == start)
        #expect(PlanPreview(draft: saved.draft).headline.hasPrefix("10K"))
    }

    @Test func aPreviewIsGoneAtTwentyFourHoursAndDeleted() throws {
        let (store, defaults) = store()
        store.save(answers: answers(), draft: try DraftFixture.draft(), now: start)
        #expect(store.load(now: start.addingTimeInterval(24 * 3600)) == nil)
        #expect(defaults.data(forKey: "preview.draft") == nil)
        #expect(store.load(now: start) == nil)
    }

    @Test func aClockSetBackIsTreatedAsExpired() throws {
        let (store, _) = store()
        store.save(answers: answers(), draft: try DraftFixture.draft(), now: start)
        #expect(store.load(now: start.addingTimeInterval(-60)) == nil)
    }

    @Test func nothingSavedAndUnreadableDataBothGiveNil() {
        let (store, defaults) = store()
        #expect(store.load(now: start) == nil)
        defaults.set(Data("not json".utf8), forKey: "preview.draft")
        #expect(store.load(now: start) == nil)
        #expect(defaults.data(forKey: "preview.draft") == nil)
    }

    @Test func savingAgainReplacesTheDraftAndRestartsTheClock() throws {
        let (store, _) = store()
        store.save(answers: answers(), draft: try DraftFixture.draft(), now: start)
        var changed = answers()
        changed.runsPerWeek = 5
        store.save(answers: changed, draft: try DraftFixture.draft(), now: start.addingTimeInterval(20 * 3600))
        let saved = try #require(store.load(now: start.addingTimeInterval(40 * 3600)))
        #expect(saved.answers.runsPerWeek == 5)
    }

    @Test func clearRemovesIt() throws {
        let (store, _) = store()
        store.save(answers: answers(), draft: try DraftFixture.draft(), now: start)
        store.clear()
        #expect(store.load(now: start) == nil)
    }
}
