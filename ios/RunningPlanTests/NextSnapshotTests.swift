import SwiftUI
import Testing
@testable import RunningPlan

/// DK-Next against `designs/dark/png/DK-Next.png`, relatively. The coarse grid cannot reliably tell one day's card
/// from another's (an intervals day against a long-run day passed on one simulator and failed on another), so the
/// text and day states are pinned by `NextModelTests` and this checks the overall layout.
@MainActor
struct NextSnapshotTests {
    private func render(today: String, board: CGImage) throws -> CGImage {
        let model = NextModel(schedule: PlanSchedule(plan: try PlanFixture.detail(), today: today))
        return try BoardSnapshot.render(NextView(model: model, onSetGoal: {}), like: board)
    }

    @Test func theBoardsDayIsNearerTheBoardThanAPlanThatHasNotStarted() throws {
        let board = try BoardSnapshot.board("DK-Next")
        let right = BoardSnapshot.difference(try render(today: PlanFixture.today, board: board), board)
        let wrong = BoardSnapshot.difference(try render(today: "2026-10-01", board: board), board)
        #expect(right < wrong, "the board's day (\(right)) should be nearer than a plan not started yet (\(wrong))")
    }
    /// DK-NextMatched (issue #186): the "Done today" card over the next session.
    @Test func theMatchedDayIsNearerItsBoardThanTheSameDayWithoutTheCard() throws {
        let board = try BoardSnapshot.board("DK-NextMatched")
        var plan = try PlanFixture.detail()
        let index = try #require(plan.value2.sessions.firstIndex { $0.value2.date == PlanFixture.today && $0.value2._type == .intervals })
        plan.value2.sessions[index].value2.status = .done
        let run = try activityFixture(
            id: "a1", date: PlanFixture.today, durationSec: 2592, distanceM: 6800, matchedSession: plan.value2.sessions[index].value1.id, disposition: "matched"
        )
        let model = NextModel(schedule: PlanSchedule(plan: plan, today: PlanFixture.today))
        let card = try #require(MatchedToday(sessions: plan.value2.sessions, runs: [run], today: PlanFixture.today, answered: []))
        let with = BoardSnapshot.difference(try BoardSnapshot.render(NextView(model: model, onSetGoal: {}, matched: card), like: board), board)
        let without = BoardSnapshot.difference(try BoardSnapshot.render(NextView(model: model, onSetGoal: {}), like: board), board)
        #expect(with < without, "with the card (\(with)) should be nearer the board than without it (\(without))")
    }
}
