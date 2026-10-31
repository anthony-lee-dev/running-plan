import SwiftUI
import Testing
@testable import RunningPlan

/// DK-Whole against `designs/dark/png/DK-Whole.png`, relatively. Text is pinned by `WholeModelTests`.
@MainActor
struct WholeSnapshotTests {
    private func render(today: String, board: CGImage) throws -> CGImage {
        let schedule = PlanSchedule(plan: try PlanFixture.detail(), today: today)
        return try BoardSnapshot.render(WholeView(model: WholeModel(schedule: schedule), onMode: { _ in }, onWeek: { _ in }), like: board)
    }

    @Test func theBoardsDayIsNearerTheBoardThanAPlanThatHasNotStarted() throws {
        // Before the start no week is current and every bar is faded.
        let board = try BoardSnapshot.board("DK-Whole")
        let right = BoardSnapshot.difference(try render(today: PlanFixture.today, board: board), board)
        let wrong = BoardSnapshot.difference(try render(today: "2026-10-01", board: board), board)
        #expect(right < wrong, "week 4 (\(right)) should be nearer the board than before the start (\(wrong))")
    }
}
