import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// Shorter, Easier, Swap and Skip on DK-Session. Each one sends more than `status`, so the server marks the session
/// the user's own (`api/src/domain/session-edit.ts` keeps `owner` only for a status-only edit).
struct QuickAdjustmentTests {
    private func content(on date: String) throws -> Components.Schemas.SessionContent {
        try SessionSheetModelTests.session(on: date).value2
    }

    private func pace(_ min: Int, _ max: Int) -> Components.Schemas.StepTarget {
        .pace(.init(_type: .pace, range: .init(minSecPerKm: min, maxSecPerKm: max)))
    }

    private func run(_ kind: Components.Schemas.RunStep.kindPayload, metres: Int, _ target: Components.Schemas.StepTarget) -> Components.Schemas.RunStep {
        .init(kind: kind, goal: .init(_type: .distance, value: metres), target: target)
    }

    @Test func shorterDropsARepeatAndKeepsTheWarmUpAndCoolDown() throws {
        let s = try content(on: "2026-10-28")
        let update = try #require(QuickAdjustment.shorter.update(for: s))
        guard case ._repeat(let group)? = update.steps?[1] else { Issue.record("no repeat"); return }
        #expect(group.count == 4)
        #expect(update.steps?.first == s.steps?.first)
        #expect(update.steps?.last == s.steps?.last)
        #expect(update._type == nil, "a shorter session keeps its type")
    }

    @Test func shorterTakesAQuarterOffARunAStrengthSetAndCrossTraining() throws {
        let easy = try #require(QuickAdjustment.shorter.update(for: try content(on: "2026-10-30")))
        let expected: [Components.Schemas.Step] = [.work(run(.work, metres: 3800, pace(385, 430)))]
        #expect(easy.steps == expected)

        let strength = try #require(QuickAdjustment.shorter.update(for: try content(on: "2026-10-27")))
        guard case .exercise(let exercise)? = strength.steps?.first else { Issue.record("no exercise"); return }
        #expect(exercise.sets == 3)

        let cycling = try #require(QuickAdjustment.shorter.update(for: try content(on: "2026-11-01")))
        #expect(cycling.custom?.goal == .init(_type: .time, value: 2040))
        #expect(cycling.custom?.activityLabel == "cycling")
    }

    @Test func shorterNeverLengthensAStepAndSkipsAnOpenCrossTraining() throws {
        var short = try content(on: "2026-10-30")
        let step: Components.Schemas.Step = .work(.init(kind: .work, goal: .init(_type: .time, value: 30)))
        short.steps = [step]
        let update = try #require(QuickAdjustment.shorter.update(for: short))
        let expected: [Components.Schemas.Step] = [step]
        #expect(update.steps == expected, "a 30 s step stays 30 s rather than growing to a minute")

        var open = try content(on: "2026-11-01")
        open.custom?.goal = .init(_type: .open)
        #expect(QuickAdjustment.shorter.update(for: open) == nil)
    }

    @Test func easierTurnsIntervalsIntoAnEasyRunOfTheSameDistance() throws {
        let update = try #require(QuickAdjustment.easier.update(for: try content(on: "2026-10-28")))
        #expect(update._type == .easy)
        #expect(update.title == "Easy run")
        #expect(update.key == false, "an easy run is not a key session")
        let expected: [Components.Schemas.Step] = [.work(run(.work, metres: 6900, pace(385, 430)))]
        #expect(update.steps == expected)
    }

    @Test func easierSlowsAnEasyRunAndEasesStrengthAndCrossTraining() throws {
        let easy = try #require(QuickAdjustment.easier.update(for: try content(on: "2026-10-30")))
        let expected: [Components.Schemas.Step] = [.work(run(.work, metres: 5000, pace(400, 445)))]
        #expect(easy.steps == expected)

        let strength = try #require(QuickAdjustment.easier.update(for: try content(on: "2026-10-27")))
        guard case .exercise(let exercise)? = strength.steps?.first else { Issue.record("no exercise"); return }
        #expect(exercise.effort == .easy)

        var hard = try content(on: "2026-11-01")
        hard.custom?.effort = .hard
        #expect(QuickAdjustment.easier.update(for: hard)?.custom?.effort == .moderate)
    }

    @Test func skipSendsTheDateTooSoTheSessionBecomesTheUsers() throws {
        let s = try content(on: "2026-10-28")
        let update = try #require(QuickAdjustment.skip.update(for: s))
        #expect(update.status == .skipped)
        #expect(update.date == s.date)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any]
        #expect(body?.count == 2, "a status-only edit would leave the session the engine's")
    }

    @Test func restHasNoAdjustments() throws {
        let rest = try #require(try PlanFixture.detail(extra: [PlanFixture.restThursday]).value2.sessions.last).value2
        for adjustment in QuickAdjustment.allCases {
            #expect(adjustment.update(for: rest) == nil)
        }
    }

    @Test func movingToAnEmptyDayMovesOnlyThatSession() throws {
        let schedule = try SessionSheetModelTests.schedule()
        let intervals = try SessionSheetModelTests.session(on: "2026-10-28")
        let edits = QuickAdjustment.move(intervals, to: "2026-10-29", in: schedule)
        let expected = [SessionEdit(sessionId: intervals.value1.id, revision: 1, update: .init(date: "2026-10-29"))]
        #expect(edits == expected)
    }

    @Test func movingOntoABusyDaySwapsTheTwo() throws {
        let schedule = try SessionSheetModelTests.schedule()
        let intervals = try SessionSheetModelTests.session(on: "2026-10-28")
        let friday = try SessionSheetModelTests.session(on: "2026-10-30")
        let edits = QuickAdjustment.move(intervals, to: "2026-10-30", in: schedule)
        let expected = [
            SessionEdit(sessionId: intervals.value1.id, revision: 1, update: .init(date: "2026-10-30")),
            SessionEdit(sessionId: friday.value1.id, revision: 1, update: .init(date: "2026-10-28")),
        ]
        #expect(edits == expected)
        #expect(QuickAdjustment.move(intervals, to: "2026-10-28", in: schedule).isEmpty, "the same day is no move")
    }

    @Test func theMoveSheetOffersTheOtherDaysOfTheWeek() throws {
        let schedule = try SessionSheetModelTests.schedule()
        let intervals = try SessionSheetModelTests.session(on: "2026-10-28")
        let days = QuickAdjustment.moveOptions(intervals, in: schedule)
        #expect(days.map(\.date) == ["2026-10-26", "2026-10-27", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"])
        #expect(days[2].label == "Thursday, Oct 29 · free")
        #expect(days[3].label == "Friday, Oct 30 · swap with Easy run")
    }

    @Test func beforeSessionFeelingsMapOntoTheFiveStepFeel() {
        #expect(BeforeFeeling.allCases.map(\.feel) == [5, 3, 2])
        #expect(BeforeFeeling.allCases.map(\.title) == ["Fresh", "Okay", "Tired"])
    }
}
