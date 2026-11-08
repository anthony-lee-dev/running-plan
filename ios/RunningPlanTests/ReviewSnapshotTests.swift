import APIClient
import SwiftUI
import Testing
@testable import RunningPlan

/// DK-Review against `designs/dark/png/DK-Review.png`, relatively (see `BoardSnapshot`). Text is pinned by
/// `ReviewModelTests` and `ProposalCardModelTests`; this checks layout and colour.
@MainActor
struct ReviewSnapshotTests {
    private func render(review: Components.Schemas.WeeklyReview, proposal: Components.Schemas.Proposal?, cards: Int = 1, board: CGImage) throws -> CGImage {
        let view = ReviewView(model: ReviewModel(review: review)) {
            if let proposal {
                ForEach(0..<cards, id: \.self) { _ in
                    ProposalCardView(model: ProposalCardModel(proposal: proposal, planContentRevision: 3), includeUserOwned: .constant(false))
                }
            }
        }
        return try BoardSnapshot.render(view, like: board)
    }

    @Test func theBoardsReviewIsNearerTheBoardThanThreeProposalsOrAnotherScreen() throws {
        let board = try BoardSnapshot.board("DK-Review")
        let review = try ReviewFixture.review()
        let right = BoardSnapshot.difference(try render(review: review, proposal: try ReviewFixture.proposal(), board: board), board)
        // Three cards push everything below them down, a layout difference the coarse grid sees on every simulator.
        let crowded = BoardSnapshot.difference(try render(review: review, proposal: try ReviewFixture.proposal(), cards: 3, board: board), board)
        let next = NextView(model: NextModel(schedule: PlanSchedule(plan: try PlanFixture.detail(), today: PlanFixture.today)), onSetGoal: {})
        let other = BoardSnapshot.difference(try BoardSnapshot.render(next, like: board), board)
        #expect(right < crowded, "the board's review (\(right)) should be nearer than one with three proposals (\(crowded))")
        #expect(right < other, "the review (\(right)) should be nearer its board than DK-Next (\(other))")
    }
}
