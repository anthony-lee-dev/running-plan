import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// DK-Editor: the editable copy of a session, its rules (the same as the server's parser in
/// `api/src/domain/plan-input.ts`) and the request it sends.
struct SessionDraftTests {
    private func content(on date: String) throws -> Components.Schemas.SessionContent {
        try SessionSheetModelTests.session(on: date).value2
    }

    @Test func anUnchangedDraftSendsNothing() throws {
        let s = try content(on: "2026-10-28")
        let draft = SessionDraft(s)
        #expect(draft.title == "Intervals: 5 × 600 m")
        #expect(draft.type == .intervals)
        #expect(draft.update(from: s) == nil)
        #expect(draft.totals == "Total ~43 min · ~6.9 km")
    }

    @Test func aNewTitleIsTheOnlyFieldSent() throws {
        let s = try content(on: "2026-10-28")
        var draft = SessionDraft(s)
        draft.title = "  My own run "
        #expect(draft.update(from: s) == .init(title: "My own run"))
        draft.title = ""
        #expect(draft.update(from: s) == .init(clear: [.title]))
    }

    @Test func notesAreSentAndCleared() throws {
        let s = try content(on: "2026-10-28")
        var draft = SessionDraft(s)
        draft.notes = "Track at the park"
        #expect(draft.update(from: s) == .init(notes: "Track at the park"))
        var withNotes = s
        withNotes.notes = "Old"
        var cleared = SessionDraft(withNotes)
        cleared.notes = ""
        #expect(cleared.update(from: withNotes) == .init(clear: [.notes]))
    }

    @Test func theRepeatCountStaysBetweenTwoAndThirty() throws {
        var draft = SessionDraft(try content(on: "2026-10-28"))
        draft.changeCount(at: 1, by: -10)
        #expect(draft.repeatCount(at: 1) == 2)
        draft.changeCount(at: 1, by: 40)
        #expect(draft.repeatCount(at: 1) == 30)
        #expect(draft.problems.isEmpty)
    }

    @Test func stepsAndRepeatsCanBeAddedMovedAndRemoved() throws {
        let s = try content(on: "2026-10-28")
        var draft = SessionDraft(s)
        draft.addStep()
        draft.addRepeat()
        #expect(draft.steps.count == 5)
        draft.addStep(toRepeatAt: 4)
        guard case ._repeat(let added) = draft.steps[4] else { Issue.record("no repeat"); return }
        #expect(added.steps.count == 3)
        draft.move(from: 4, to: 0)
        guard case ._repeat = draft.steps[0] else { Issue.record("not moved"); return }
        draft.remove(at: 0)
        draft.remove(at: 3)
        #expect(draft.steps == s.steps)
        #expect(draft.update(from: s) == nil)
    }

    @Test func aRepeatKeepsOneToTenSteps() throws {
        var draft = SessionDraft(try content(on: "2026-10-28"))
        for _ in 0..<12 { draft.addStep(toRepeatAt: 1) }
        guard case ._repeat(let group) = draft.steps[1] else { Issue.record("no repeat"); return }
        #expect(group.steps.count == 10)
        draft.removeChild(1, at: 0)
        draft.removeChild(1, at: 0)
        for _ in 0..<10 { draft.removeChild(1, at: 0) }
        guard case ._repeat(let one) = draft.steps[1] else { Issue.record("repeat dropped"); return }
        #expect(one.steps.count == 1)
    }

    @Test func changingTheKindOfSessionStartsItsStepsAfresh() throws {
        let s = try content(on: "2026-10-28")
        var draft = SessionDraft(s)
        draft.setType(.tempo)
        #expect(draft.steps == s.steps, "runs keep their steps")
        draft.setType(.strength)
        #expect(draft.steps.allSatisfy { if case .exercise = $0 { true } else { false } })
        #expect(!draft.steps.isEmpty)
        draft.setType(.custom)
        #expect(draft.steps.isEmpty)
        let update = try #require(draft.update(from: s))
        #expect(update._type == .custom)
        #expect(update.steps == nil, "the server drops the old steps itself")
        #expect(update.custom == .init(activityLabel: nil, goal: .init(_type: .time, value: 1800), effort: .easy))
    }

    @Test func aRunNeedsAStepAndACustomGoalNeedsAValue() throws {
        var draft = SessionDraft(try content(on: "2026-10-30"))
        draft.remove(at: 0)
        #expect(draft.problems == ["Add at least one step."])
        draft.setType(.custom)
        draft.custom.goal = .init(_type: .time, value: 0)
        #expect(draft.problems == ["Give the session a time or distance."])
        draft.custom.goal = .init(_type: .open)
        #expect(draft.problems.isEmpty)
    }

    @Test func aStepWithoutATimeOrDistanceStopsTheSave() throws {
        var draft = SessionDraft(try content(on: "2026-10-28"))
        guard let fast = draft.runStep(1, child: 0) else { Issue.record("no fast step"); return }
        var empty = fast
        empty.goal = .init(_type: .distance, value: 0)
        draft.setRunStep(1, child: 0, empty)
        #expect(draft.problems == ["Give every step a time or distance, or make it open."])
        empty.goal = .init(_type: .open)
        draft.setRunStep(1, child: 0, empty)
        #expect(draft.problems.isEmpty)
    }

    @Test func aNewSessionIsTheUsersAndSendsItsContent() throws {
        var draft = SessionDraft.new(date: "2026-10-29")
        #expect(draft.type == .easy)
        draft.title = "Recovery jog"
        let body = draft.create(id: "11111111-1111-4111-8111-111111111111")
        #expect(body.value2.id == "11111111-1111-4111-8111-111111111111")
        #expect(body.value1.date == "2026-10-29")
        #expect(body.value1.owner == .user)
        #expect(body.value1.title == "Recovery jog")
        #expect(body.value1.steps?.count == 1)
        #expect(body.value1.custom == nil)
        #expect(body.value1.notes == nil)

        draft.setType(.custom)
        draft.custom.activityLabel = "Swimming"
        let swim = draft.create(id: "11111111-1111-4111-8111-111111111111").value1
        #expect(swim.steps == nil)
        #expect(swim.custom?.activityLabel == "Swimming")
    }

    @Test func timeDialsSplitAndRejoinASavedTime() {
        #expect(DialValues.minutes(3725) == 62)
        #expect(DialValues.secondsPart(3725) == 5)
        #expect(DialValues.time(minutes: 62, seconds: 5) == 3725)
        #expect(DialValues.time(minutes: 0, seconds: 0) == 1, "the API needs at least one second")
        // The wheel reaches the API's longest goal, so moving the seconds wheel never shortens a saved one.
        #expect(DialValues.time(minutes: DialValues.minutes(199_990), seconds: DialValues.secondsPart(199_990)) == 199_990)
        #expect(DialValues.time(minutes: 3333, seconds: 59) == 200_000, "capped at the API maximum")
    }

    @Test func distanceDialsShowASavedDistanceAndKeepWhatTheyDidNotTouch() {
        #expect(DialValues.km(1250) == 1)
        #expect(DialValues.hundredths(1250) == 25)
        #expect(DialValues.km(10000) == 10)
        #expect(DialValues.hundredths(10000) == 0)
        #expect(DialValues.hundredths(250) == 25)
        // 1234 m is off the 10 m grid: moving the km wheel keeps its 234 m, moving the decimal wheel sets 10 m steps.
        #expect(DialValues.distance(km: 3, keepingFractionOf: 1234) == 3234)
        #expect(DialValues.distance(hundredths: 50, keepingKmOf: 1234) == 1500)
        #expect(DialValues.distance(km: 0, keepingFractionOf: 0) == 10, "never zero")
        #expect(DialValues.distance(km: 200, keepingFractionOf: 990) == 200_000, "capped at the API maximum")
    }

    @Test func distanceFractionWheelGoesInTenthsAndKeepsAnOffGridSavedValue() {
        #expect(DialValues.fractionOptions(1500) == [0, 10, 20, 30, 40, 50, 60, 70, 80, 90])
        // 1250 m (1.25 km) was saved at two decimals: its own step is added so it still shows, and nothing rewrites it.
        #expect(DialValues.fractionOptions(1250) == [0, 10, 20, 25, 30, 40, 50, 60, 70, 80, 90])
        #expect(DialValues.hundredths(1250) == 25)
        #expect(DialValues.distance(hundredths: 25, keepingKmOf: 1250) == 1250)
        #expect(DialValues.distance(hundredths: 30, keepingKmOf: 1250) == 1300)
        #expect(DialValues.fractionLabel(50) == ".5")
        #expect(DialValues.fractionLabel(0) == ".0")
        #expect(DialValues.fractionLabel(25) == ".25")
    }

    @Test func paceDialsStayWithinTheAPIRange() {
        #expect(DialValues.paceMinutes(315) == 5)
        #expect(DialValues.paceSecondsPart(315) == 15)
        #expect(DialValues.pace(minutes: 5, seconds: 15) == 315)
        #expect(DialValues.pace(minutes: 2, seconds: 0) == 120)
        #expect(DialValues.pace(minutes: 20, seconds: 59) == 1200)
        #expect(DialValues.pace(minutes: 1, seconds: 0) == 120)
        #expect(DialValues.pace(minutes: 20, seconds: 30) == 1200)
    }
}
