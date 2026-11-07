import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// Answers the review and proposal calls from a script and records them.
private actor FakeReview: ReviewServing {
    typealias Review = Components.Schemas.WeeklyReview
    typealias Proposal = Components.Schemas.Proposal

    private(set) var calls: [String] = []
    /// The review for each week index; weeks not listed are not in the plan.
    var reviews: [Int: Review] = [:]
    var generated: [Proposal] = []
    var generateError: ReviewError?
    var pendingList: [Proposal] = []
    var acceptResult: Result<Components.Schemas.PlanDetail, ReviewError> = .failure(.server)
    var dismissError: ReviewError?

    func set(reviews: [Int: Review]) { self.reviews = reviews }
    func set(generated: [Proposal], error: ReviewError? = nil) { self.generated = generated; generateError = error }
    func set(pending: [Proposal]) { pendingList = pending }
    func set(accept: Result<Components.Schemas.PlanDetail, ReviewError>) { acceptResult = accept }
    func set(dismissError: ReviewError?) { self.dismissError = dismissError }

    func review(planId: String, weekIndex: Int, today: String) async throws -> Review? {
        calls.append("review \(weekIndex)")
        return reviews[weekIndex]
    }

    func generate(planId: String, today: String, interview: Components.Schemas.InterviewAnswers?) async throws -> [Proposal] {
        calls.append(interview == nil ? "generate" : "generate interview")
        if let generateError { throw generateError }
        return generated
    }

    func pending(planId: String) async throws -> [Proposal] {
        calls.append("pending")
        return pendingList
    }

    func accept(id: String, includeUserOwned: Bool) async throws -> Components.Schemas.PlanDetail {
        calls.append("accept \(id) \(includeUserOwned)")
        return try acceptResult.get()
    }

    func dismiss(id: String) async throws {
        calls.append("dismiss \(id)")
        if let dismissError { throw dismissError }
    }
}

private actor Loader: PlanLoading {
    private(set) var calls: [String] = []
    func activePlan() async throws -> Components.Schemas.PlanDetail? { try PlanFixture.detail() }
    func plan(id: String) async throws -> Components.Schemas.PlanDetail? {
        calls.append("plan \(id)")
        return try PlanFixture.detail()
    }
}

private actor SignedIn: SignInService {
    let isSignedIn = true
    func startEmailSignIn(email: String) async throws {}
    func verify(email: String, code: String) async throws {}
}

/// The plan, with its content revision moved on (what an accepted proposal does).
private func movedOn(to revision: Int) throws -> Components.Schemas.PlanDetail {
    var detail = try PlanFixture.detail()
    detail.value1.value3.contentRevision = revision
    return detail
}

@MainActor
private func makeStores(_ service: FakeReview, loader: Loader = Loader()) async throws -> (plans: PlanStore, proposals: ProposalsStore, review: ReviewStore) {
    let plans = PlanStore(loader: loader, account: SignedIn(), writer: FakeWriter())
    await plans.show(planId: PlanFixture.planID)
    let proposals = ProposalsStore(service: service, plans: plans)
    return (plans, proposals, ReviewStore(service: service, proposals: proposals))
}

// MARK: Proposals

@MainActor
struct ProposalsStoreTests {
    @Test func acceptingAppliesTheProposalToThePlanAndLeavesAnAppliedRow() async throws {
        let service = FakeReview()
        await service.set(accept: .success(try movedOn(to: 4)))
        let (plans, proposals, _) = try await makeStores(service)
        proposals.show([try ReviewFixture.proposal()], planId: PlanFixture.planID)

        let applied = await proposals.accept(ReviewFixture.proposalID)

        #expect(applied)
        #expect(await service.calls == ["accept \(ReviewFixture.proposalID) false"])
        #expect(plans.plan?.value1.value3.contentRevision == 4, "the server's plan replaces ours")
        #expect(proposals.proposals.isEmpty)
        #expect(proposals.applied.map(\.title) == ["Ease Saturday's long run"])
    }

    @Test func includingMySessionsIsSentWithTheAccept() async throws {
        let service = FakeReview()
        await service.set(accept: .success(try movedOn(to: 4)))
        let (_, proposals, _) = try await makeStores(service)
        proposals.show([try ReviewFixture.proposal()], planId: PlanFixture.planID)
        proposals.setIncluded(true, for: ReviewFixture.proposalID)

        _ = await proposals.accept(ReviewFixture.proposalID)

        #expect(await service.calls == ["accept \(ReviewFixture.proposalID) true"])
    }

    @Test func otherProposalsGoStaleAtOnceWhenOneIsAccepted() async throws {
        let service = FakeReview()
        await service.set(accept: .success(try movedOn(to: 4)))
        let (_, proposals, _) = try await makeStores(service)
        proposals.show([try ReviewFixture.proposal(), try ReviewFixture.proposal(id: ReviewFixture.otherProposalID)], planId: PlanFixture.planID)
        #expect(proposals.cards().map(\.stale) == [false, false])

        _ = await proposals.accept(ReviewFixture.proposalID)

        let cards = proposals.cards()
        #expect(cards.map(\.id) == [ReviewFixture.otherProposalID])
        #expect(cards.map(\.stale) == [true], "built on revision 3, the plan is now on 4")
    }

    @Test func aStaleAnswerReloadsThePlanAndKeepsTheCardWithAReason() async throws {
        let service = FakeReview()
        await service.set(accept: .failure(.stale))
        let loader = Loader()
        let (_, proposals, _) = try await makeStores(service, loader: loader)
        proposals.show([try ReviewFixture.proposal()], planId: PlanFixture.planID)

        let applied = await proposals.accept(ReviewFixture.proposalID)

        #expect(!applied)
        #expect(await loader.calls == ["plan \(PlanFixture.planID)", "plan \(PlanFixture.planID)"], "once to load, once after the 409")
        #expect(proposals.proposals.count == 1)
        #expect(proposals.errors[ReviewFixture.proposalID] == "This suggestion is out of date. Refresh to get a new one.")
    }

    @Test func aProposalAlreadyDecidedElsewhereIsRemovedAfterReloadingTheList() async throws {
        let service = FakeReview()
        await service.set(accept: .failure(.notPending))
        await service.set(pending: [])
        let (_, proposals, _) = try await makeStores(service)
        proposals.show([try ReviewFixture.proposal()], planId: PlanFixture.planID)

        _ = await proposals.accept(ReviewFixture.proposalID)

        #expect(await service.calls.last == "pending")
        #expect(proposals.proposals.isEmpty)
        #expect(proposals.applied.isEmpty)
    }

    @Test func aFailedAcceptKeepsTheCardAndExplains() async throws {
        let service = FakeReview()
        await service.set(accept: .failure(.offline))
        let (_, proposals, _) = try await makeStores(service)
        proposals.show([try ReviewFixture.proposal()], planId: PlanFixture.planID)

        let applied = await proposals.accept(ReviewFixture.proposalID)

        #expect(!applied)
        #expect(proposals.proposals.count == 1)
        #expect(proposals.errors[ReviewFixture.proposalID] == "We couldn't reach the server. Check your connection and try again.")
        #expect(!proposals.isWorking(ReviewFixture.proposalID))
    }

    @Test func dismissingRemovesTheCard() async throws {
        let service = FakeReview()
        let (_, proposals, _) = try await makeStores(service)
        proposals.show([try ReviewFixture.proposal(), try ReviewFixture.proposal(id: ReviewFixture.otherProposalID)], planId: PlanFixture.planID)

        let done = await proposals.dismiss(ReviewFixture.proposalID)

        #expect(done)
        #expect(await service.calls == ["dismiss \(ReviewFixture.proposalID)"])
        #expect(proposals.proposals.map(\.id) == [ReviewFixture.otherProposalID])
        #expect(proposals.applied.isEmpty)
    }

    @Test func refreshingMakesNewProposalsAndDropsTheOutOfDateOnes() async throws {
        let service = FakeReview()
        let fresh = try ReviewFixture.proposal(id: ReviewFixture.otherProposalID, base: 4)
        await service.set(generated: [fresh])
        await service.set(pending: [fresh])
        let (_, proposals, _) = try await makeStores(service)
        proposals.show([try ReviewFixture.proposal()], planId: PlanFixture.planID)

        await proposals.refresh(today: PlanFixture.today)

        #expect(await service.calls == ["generate", "pending"])
        #expect(proposals.proposals.map(\.id) == [ReviewFixture.otherProposalID])
    }

    @Test func anInterviewRerunIsShownAsAProposalForSettingsToPresent() async throws {
        let service = FakeReview()
        let rerun = try ReviewFixture.proposal(kind: "interview_rerun", changes: [ReviewFixture.change(before: 8000, after: 9000)])
        await service.set(generated: [rerun])
        await service.set(pending: [rerun])
        let (_, proposals, _) = try await makeStores(service)
        let answers = try APIConfiguration.decoder.decode(Components.Schemas.InterviewAnswers.self, from: Data(#"{"goal":{"distance":"10k"}}"#.utf8))

        let error = await proposals.proposeInterviewRerun(planId: PlanFixture.planID, today: PlanFixture.today, answers: answers)

        #expect(error == nil)
        #expect(await service.calls == ["generate interview"])
        #expect(proposals.proposals.map(\.id) == [ReviewFixture.proposalID])
        #expect(proposals.cards().first?.isRerun == true)
    }
}

// MARK: Review

@MainActor
struct ReviewStoreTests {
    private func week(_ index: Int, due: Bool, proposals: [String] = []) throws -> Components.Schemas.WeeklyReview {
        try ReviewFixture.review(week: index, due: due, proposals: proposals)
    }

    @Test func theDueWeekIsFoundFromThisWeekBackwards() async throws {
        // Wed 2026-10-28 is in week 4 (index 3); the week 3 review is due until the end of this week.
        let service = FakeReview()
        await service.set(reviews: [3: try week(3, due: false, proposals: []), 2: try week(2, due: true), 1: try week(1, due: false)])
        let (plans, _, review) = try await makeStores(service)

        await review.load(plan: try #require(plans.plan), today: PlanFixture.today)

        #expect(review.review?.weekIndex == 2)
        #expect(review.isDue)
        #expect(await service.calls == ["review 3", "review 2", "generate", "review 2"], "generate when the review is due, then read it again")
    }

    @Test func theProposalsFromTheReviewAreHandedToTheList() async throws {
        let service = FakeReview()
        await service.set(reviews: [3: try week(3, due: true, proposals: [ReviewFixture.proposalJSON()])])
        let (plans, proposals, review) = try await makeStores(service)

        await review.load(plan: try #require(plans.plan), today: PlanFixture.today)

        #expect(proposals.proposals.map(\.id) == [ReviewFixture.proposalID])
    }

    @Test func nothingDueAndNothingPendingShowsNoReview() async throws {
        let service = FakeReview()
        await service.set(reviews: [3: try week(3, due: false), 2: try week(2, due: false), 1: try week(1, due: false)])
        let (plans, _, review) = try await makeStores(service)

        await review.load(plan: try #require(plans.plan), today: PlanFixture.today)

        #expect(review.review == nil)
        #expect(await service.calls == ["review 3", "review 2", "review 1"], "never further back than two weeks, and no generate")
    }

    @Test func anUrgentProposalShowsThisWeeksReviewEvenWhenNothingIsDue() async throws {
        let service = FakeReview()
        let urgent = ReviewFixture.proposalJSON(urgent: true)
        await service.set(reviews: [3: try week(3, due: false, proposals: [urgent]), 2: try week(2, due: false), 1: try week(1, due: false)])
        let (plans, _, review) = try await makeStores(service)

        await review.load(plan: try #require(plans.plan), today: PlanFixture.today)

        #expect(review.review?.weekIndex == 3)
        #expect(!review.isDue)
    }

    @Test func aPlanThatHasNotStartedHasNoReview() async throws {
        let service = FakeReview()
        let (plans, _, review) = try await makeStores(service)

        await review.load(plan: try #require(plans.plan), today: "2026-09-20")

        #expect(review.review == nil)
        #expect(await service.calls.isEmpty)
    }

    @Test func aFinishedPlanLooksAtItsLastWeeks() async throws {
        let service = FakeReview()
        await service.set(reviews: [9: try week(9, due: true)])
        let (plans, _, review) = try await makeStores(service)

        await review.load(plan: try #require(plans.plan), today: "2026-12-16")

        #expect(review.review?.weekIndex == 9)
        #expect(await service.calls.first == "review 9")
    }

    @Test func proposalsAreMadeOncePerPlanRevision() async throws {
        let service = FakeReview()
        await service.set(reviews: [3: try week(3, due: true)])
        let (plans, _, review) = try await makeStores(service)
        let plan = try #require(plans.plan)

        await review.load(plan: plan, today: PlanFixture.today)
        await review.load(plan: plan, today: PlanFixture.today)
        let generates = await service.calls.filter { $0 == "generate" }
        #expect(generates.count == 1, "opening Next again does not ask the engine again")

        await review.load(plan: try movedOn(to: 4), today: PlanFixture.today)
        let after = await service.calls.filter { $0 == "generate" }
        #expect(after.count == 2, "an import or an edit moves the revision, so the engine looks again")
    }

    @Test func aFailedGenerateStillShowsTheReview() async throws {
        let service = FakeReview()
        await service.set(reviews: [3: try week(3, due: true)])
        await service.set(generated: [], error: .server)
        let (plans, _, review) = try await makeStores(service)

        await review.load(plan: try #require(plans.plan), today: PlanFixture.today)

        #expect(review.review?.weekIndex == 3)
    }

    @Test func theOpenReviewStaysWhenItsLastSuggestionIsAccepted() async throws {
        let service = FakeReview()
        let urgent = ReviewFixture.proposalJSON(urgent: true)
        await service.set(reviews: [3: try week(3, due: false, proposals: [urgent])])
        let (plans, proposals, review) = try await makeStores(service)
        await review.load(plan: try #require(plans.plan), today: PlanFixture.today)
        #expect(review.isWaiting)

        // The suggestion was accepted: nothing is pending and nothing is due.
        await service.set(reviews: [3: try week(3, due: false, proposals: [])])
        await review.load(plan: try movedOn(to: 4), today: PlanFixture.today, keepingOpen: true)
        #expect(review.isWaiting, "the screen is still showing it")
        #expect(proposals.proposals.isEmpty)

        await review.load(plan: try movedOn(to: 4), today: PlanFixture.today)
        #expect(!review.isWaiting, "once closed, Next has nothing to offer")
    }

    @Test func aReviewThatIsGoneClearsWhatWasShown() async throws {
        let service = FakeReview()
        await service.set(reviews: [3: try week(3, due: true)])
        let (plans, _, review) = try await makeStores(service)
        await review.load(plan: try #require(plans.plan), today: PlanFixture.today)

        await service.set(reviews: [:])
        await review.load(plan: try movedOn(to: 4), today: PlanFixture.today)

        #expect(review.review == nil, "the plan's weeks are gone, so there is nothing to show")
    }
}
