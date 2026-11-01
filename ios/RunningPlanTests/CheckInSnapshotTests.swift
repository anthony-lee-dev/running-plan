import SwiftUI
import Testing
@testable import RunningPlan

/// DK-CheckIn against `designs/dark/png/DK-CheckIn.png`, relatively (see `BoardSnapshot`). Text is pinned by
/// `CheckInModelTests`; this checks layout, colour and the selected answers.
@MainActor
struct CheckInSnapshotTests {
    private func render(_ feeling: AfterFeeling?, pain: Bool, board: CGImage) throws -> CGImage {
        let view = CheckInView(model: try CheckInModelTests.board(), feeling: .constant(feeling), pain: .constant(pain))
        return try BoardSnapshot.render(view, like: board)
    }

    @Test func theBoardsAnswersAreNearerTheBoardThanOthersOrAnotherScreen() throws {
        let board = try BoardSnapshot.board("DK-CheckIn")
        let right = BoardSnapshot.difference(try render(.aboutRight, pain: false, board: board), board)
        let wrong = BoardSnapshot.difference(try render(.easier, pain: true, board: board), board)
        let next = NextView(model: NextModel(schedule: PlanSchedule(plan: try PlanFixture.detail(), today: PlanFixture.today)), onSetGoal: {})
        let other = BoardSnapshot.difference(try BoardSnapshot.render(next, like: board), board)
        #expect(right < wrong, "the board's answers (\(right)) should be nearer than Easier with pain (\(wrong))")
        #expect(right < other, "the check-in (\(right)) should be nearer its board than DK-Next (\(other))")
    }
}
