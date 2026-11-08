import APIClient
import Foundation
import Observation

/// The weekly review Next offers and DK-Review shows. The server decides when a review is due (from the review
/// frequency and day), so this only looks: from this week back, the first week whose review is `due` is the one to show.
/// With a different review day that can be up to two weeks back. When nothing is due but proposals are waiting (an
/// urgent one raised by a pain flag), this week's review is shown for them.
///
/// The review endpoint never makes proposals, so a due review asks the engine once per plan revision (`generate`
/// follows the review setting on the server: Off makes none). Every import and edit moves the revision, which covers
/// "After every import" without touching the inbox.
@MainActor
@Observable
final class ReviewStore {
    typealias Review = Components.Schemas.WeeklyReview

    /// How many weeks before this one are looked at.
    static let lookback = 2

    private(set) var review: Review?
    private(set) var error: String?
    private(set) var loading = false
    let proposals: ProposalsStore
    private let service: ReviewServing
    private var generated: Set<String> = []

    init(service: ReviewServing, proposals: ProposalsStore) {
        self.service = service
        self.proposals = proposals
    }

    var model: ReviewModel? { review.map(ReviewModel.init) }
    var isDue: Bool { review?.due == true }
    /// Something for Next to offer: a review that is due, or proposals waiting.
    var isWaiting: Bool { review != nil }

    /// `keepingOpen`: the review screen is up, so a review that stops being waiting stays shown until it closes.
    func load(plan: Components.Schemas.PlanDetail, today: String, keepingOpen: Bool = false) async {
        let schedule = PlanSchedule(plan: plan, today: today)
        let planId = plan.value1.value1.id
        let current: Int
        switch schedule.position {
        case .notStarted:
            adopt(nil, planId: planId)
            return
        case .week(let week): current = week
        case .finished: current = schedule.weekCount - 1
        }
        loading = true
        defer { loading = false }
        do {
            var thisWeek: Review?
            var due: Review?
            for week in stride(from: current, through: max(0, current - Self.lookback), by: -1) {
                guard let found = try await service.review(planId: planId, weekIndex: week, today: today) else { continue }
                if week == current { thisWeek = found }
                if found.due {
                    due = found
                    break
                }
            }
            if let first = due {
                let key = "\(planId)|\(first.weekIndex)|\(plan.value1.value3.contentRevision)"
                var shown = first
                // Claimed before the call, so two loads at once (RootView's and the screen's) ask the engine only once.
                if generated.insert(key).inserted {
                    if (try? await service.generate(planId: planId, today: today, interview: nil)) == nil {
                        generated.remove(key)
                    } else if let again = try await service.review(planId: planId, weekIndex: first.weekIndex, today: today) { shown = again }
                }
                adopt(shown, planId: planId)
            } else if let thisWeek, !thisWeek.proposals.isEmpty {
                adopt(thisWeek, planId: planId)
            } else if keepingOpen, review != nil {
                // The screen is showing this review (the last suggestion was just accepted): leave it, with its Applied rows.
                proposals.show([], planId: planId)
            } else {
                adopt(nil, planId: planId)
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            // Next keeps what it showed; the review screen offers a retry.
            self.error = switch error {
            case ReviewError.offline: "We couldn't reach the server. Check your connection and try again."
            case ReviewError.signedOut: "You've been signed out. Sign in again to see your review."
            default: "Something went wrong loading your review. Please try again."
            }
        }
    }

    /// No plan to review (signed out, account or plan deleted): forget the review, so no badge outlives it.
    func clear() {
        review = nil
        error = nil
        generated = []
        proposals.show([], planId: "")
    }

    private func adopt(_ review: Review?, planId: String) {
        self.review = review
        proposals.show(review?.proposals ?? [], planId: planId)
    }
}
