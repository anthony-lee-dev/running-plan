import SwiftUI
import Testing
@testable import RunningPlan

/// DK-Progress against `designs/dark/png/DK-Progress.png`, relatively. Text is pinned by `ProgressModelTests`.
@MainActor
struct ProgressSnapshotTests {
    private func render(_ model: ProgressModel, board: CGImage) throws -> CGImage {
        try BoardSnapshot.render(ProgressOverview(model: model), like: board)
    }

    @Test func theBoardsWeekIsNearerTheBoardThanAPlanThatHasNotStarted() throws {
        let board = try BoardSnapshot.board("DK-Progress")
        let notStarted = try ProgressFixture.progress(
            asOf: "2026-10-01", adherence: .init(due: 0, done: 0, skipped: 0, missed: 0), key: (0, 0), strength: (0, 0),
            goal: #"{"date":"2026-12-13","daysToGo":73,"onTrack":"unknown"}"#, ran: Array(repeating: 0, count: 10)
        )
        let rendered = try render(try ProgressFixture.model(), board: board)
        let right = BoardSnapshot.difference(rendered, board)
        let wrong = BoardSnapshot.difference(try render(try ProgressFixture.model(progress: notStarted), board: board), board)
        #expect(right < wrong, "week 4 (\(right)) should be nearer the board than before the start (\(wrong))")
        let otherScreen = BoardSnapshot.difference(rendered, try BoardSnapshot.board("DK-Whole"))
        #expect(right < otherScreen, "the board (\(right)) should be nearer than DK-Whole (\(otherScreen))")
    }
}
