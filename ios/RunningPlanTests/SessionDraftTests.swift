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

    @Test func editableStepValuesRoundTrip() {
        #expect(StepFormat.parseTime("10:00") == 600)
        #expect(StepFormat.parseTime("1:02:05") == 3725)
        #expect(StepFormat.parseTime("45") == 2700, "a bare number is minutes")
        #expect(StepFormat.parseTime("x") == nil)
        #expect(StepFormat.parsePace("5:15") == 315)
        #expect(StepFormat.parsePace("15") == nil)
    }
}
