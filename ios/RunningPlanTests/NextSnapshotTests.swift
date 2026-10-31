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

}
