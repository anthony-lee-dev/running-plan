import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct RunMatchModelTests {
    private func sessions() throws -> [Components.Schemas.Session] { try PlanFixture.detail().value2.sessions }
    private func easy(_ date: String) throws -> Components.Schemas.Session {
        try #require(sessions().first { $0.value2.date == date && $0.value2._type == .easy })
    }

    @Test func theMatchedRunIsFoundByItsSession() throws {
        let monday = try easy("2026-10-26")
        let mine = try activityFixture(id: "a1", date: "2026-10-26", matchedSession: monday.value1.id, disposition: "matched")
        let other = try activityFixture(id: "a2", date: "2026-10-26")
        #expect(RunMatchModel.matchedRun(for: monday.value1.id, in: [other, mine])?.value2.id == "a1")
        #expect(RunMatchModel.matchedRun(for: monday.value1.id, in: [other]) == nil)
    }

    @Test func matchingIsOfferedForTodayAndEarlierOnly() throws {
        let monday = try easy("2026-10-26")
        #expect(RunMatchModel.canMatch(monday, today: "2026-10-26"))
        #expect(RunMatchModel.canMatch(monday, today: "2026-10-30"))
        #expect(!RunMatchModel.canMatch(monday, today: "2026-10-25"))
    }

    @Test func candidatesAreInboxRunsOfAFittingTypeNearestFirst() throws {
        let monday = try easy("2026-10-26")
        let far = try activityFixture(id: "far", date: "2026-10-20")
        let near = try activityFixture(id: "near", date: "2026-10-27")
        let strength = try activityFixture(id: "gym", date: "2026-10-26", type: "strength")
        let taken = try activityFixture(id: "taken", date: "2026-10-26", matchedSession: "x", disposition: "matched")
        let ids = RunMatchModel.candidates(for: monday, in: [far, strength, taken, near]).map(\.value2.id)
        let expected = ["near", "far"]
        #expect(ids == expected)
    }

    @Test func extraAndIgnoredRunsAreOfferedAndTaggedButMatchedOnesAreNot() throws {
        let monday = try easy("2026-10-26")
        let inbox = try activityFixture(id: "inbox", date: "2026-10-26")
        let extra = try activityFixture(id: "extra", date: "2026-10-27", disposition: "extra")
        let ignored = try activityFixture(id: "ignored", date: "2026-10-28", disposition: "ignored")
        let gym = try activityFixture(id: "gym", date: "2026-10-26", type: "strength", disposition: "extra")
        let taken = try activityFixture(id: "taken", date: "2026-10-26", matchedSession: "x", disposition: "matched")
        let found = RunMatchModel.candidates(for: monday, in: [taken, gym, ignored, extra, inbox])
        #expect(found.map(\.value2.id) == ["inbox", "extra", "ignored"])
        #expect(found.map { RunMatchModel.row(for: $0).tag } == [nil, "Extra run", "Ignored"])
    }

    // Issue #131: Match / Change / Unmatch inside Run details.
    @Test func runDetailsOffersTheActionsForWhereTheRunStands() {
        let matched = RunsModel.Status.matched(sessionId: "s1", label: "Easy run")
        let changeAndUnmatch: [RunAction] = [.change, .unmatch]
        #expect(RunMatchModel.actions(for: matched, sessionExists: true) == changeAndUnmatch)
        let onlyMatch: [RunAction] = [.match]
        #expect(RunMatchModel.actions(for: .inbox, sessionExists: false) == onlyMatch)
        let matchAndBack: [RunAction] = [.match, .backToInbox]
        #expect(RunMatchModel.actions(for: .extra, sessionExists: false) == matchAndBack)
        #expect(RunMatchModel.actions(for: .ignored, sessionExists: false) == matchAndBack)
    }

    @Test func aRunMatchedToAGoneSessionCanBeMovedButNotUnmatched() {
        let gone = RunsModel.Status.matched(sessionId: "s1", label: "a session no longer in your plan")
        let onlyChange: [RunAction] = [.change]
        #expect(RunMatchModel.actions(for: gone, sessionExists: false) == onlyChange)
    }

    @Test func theRunsListShowsWhereEachRunStands() throws {
        let monday = try easy("2026-10-26")
        let matched = try activityFixture(id: "a1", date: "2026-10-26", matchedSession: monday.value1.id, disposition: "matched")
        let extra = try activityFixture(id: "a2", date: "2026-10-25", disposition: "extra")
        let waiting = try activityFixture(id: "a3", date: "2026-10-26")
        var all = try sessions()
        if let i = all.firstIndex(where: { $0.value1.id == monday.value1.id }) { all[i].value2.status = .done }
        let model = RunsModel(activities: [matched, extra, waiting], sessions: all, today: "2026-10-28")
        #expect(model.rows[0].status == .matched(sessionId: monday.value1.id, label: "Easy run · 5 km on Mon, Oct 26"))
        #expect(model.rows[1].status == .extra)
        #expect(model.rows[2].status == .inbox)
        // Monday is done, so it is not offered to the waiting run.
        #expect(!model.choices(for: "a3").contains { $0.id == monday.value1.id })
    }
}
