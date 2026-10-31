import SwiftUI
import Testing
@testable import RunningPlan

/// DK-Week against `designs/dark/png/DK-Week.png`, relatively. Text and day states are pinned by `WeekModelTests`.
@MainActor
struct WeekSnapshotTests {
    private func render(week: Int, board: CGImage) throws -> CGImage {
        let schedule = PlanSchedule(plan: try PlanFixture.detail(), today: PlanFixture.today)
        return try BoardSnapshot.render(WeekView(model: WeekModel(schedule: schedule, week: week), onWeek: { _ in }), like: board)
    }

    @Test func theBoardsWeekIsNearerTheBoardThanTheFirstWeek() throws {
        // Week 1 is all done, with no today and no rest-day card.
        let board = try BoardSnapshot.board("DK-Week")
        let right = BoardSnapshot.difference(try render(week: 3, board: board), board)
        let wrong = BoardSnapshot.difference(try render(week: 0, board: board), board)
        #expect(right < wrong, "week 4 (\(right)) should be nearer the board than week 1 (\(wrong))")
    }
}
