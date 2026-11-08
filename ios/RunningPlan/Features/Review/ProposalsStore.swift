import APIClient
import Foundation
import Observation

/// A plan's pending proposals and what the user does with them: accept (the server applies it and returns the whole
/// plan, which replaces ours), dismiss, or refresh when the plan moved on. Reusable: the weekly review fills it from the
/// review, and Goal and settings (#77) fills it with the interview re-run (`proposeInterviewRerun`) and presents
/// `ProposalList` for it. Proposals never apply themselves.
@MainActor
@Observable
final class ProposalsStore {
    typealias Proposal = Components.Schemas.Proposal

    /// A proposal just accepted: collapses to a one-line "Applied" row until the list is shown again.
    struct Applied: Equatable, Identifiable {
        let id: String
        let title: String
    }

    private(set) var planId: String?
    private(set) var proposals: [Proposal] = []
    private(set) var applied: [Applied] = []
    /// A sentence per proposal for a failed accept or dismiss.
    private(set) var errors: [String: String] = [:]
    private(set) var refreshing = false
    private var working: Set<String> = []
    private var included: Set<String> = []

    private let service: ReviewServing
    private let plans: PlanStore

    init(service: ReviewServing, plans: PlanStore) {
        self.service = service
        self.plans = plans
    }

    /// Replaces the list, for example with the proposals a review or an interview re-run returned. Applied rows stay for
    /// the same plan and go with a different one.
    func show(_ proposals: [Proposal], planId: String) {
        if self.planId != planId { applied = [] }
        self.planId = planId
        let ids = Set(proposals.map(\.id))
        errors = errors.filter { ids.contains($0.key) }
        included.formIntersection(ids)
        self.proposals = proposals
    }

    /// The cards, with stale worked out against the plan as it is now.
    func cards() -> [ProposalCardModel] {
        let revision = plans.plan?.value1.value3.contentRevision
        return proposals.map { ProposalCardModel(proposal: $0, planContentRevision: revision) }
    }

    func isWorking(_ id: String) -> Bool { working.contains(id) }
    func includesUserOwned(_ id: String) -> Bool { included.contains(id) }

    func setIncluded(_ on: Bool, for id: String) {
        if on { included.insert(id) } else { included.remove(id) }
    }

    /// Applies the proposal. True when the server applied it and the plan now shows it.
    func accept(_ id: String) async -> Bool {
        guard !working.contains(id), let proposal = proposals.first(where: { $0.id == id }) else { return false }
        working.insert(id)
        errors[id] = nil
        defer { working.remove(id) }
        let title = cards().first { $0.id == id }?.title ?? "Suggestion"
        do {
            let plan = try await service.accept(id: id, includeUserOwned: included.contains(id))
            plans.replace(plan: plan)
            proposals.removeAll { $0.id == id }
            applied.append(Applied(id: id, title: title))
            return true
        } catch ReviewError.stale {
            // The plan moved since this was suggested: load the latest one, so the card shows as out of date.
            await reloadPlan(proposal.planId)
            errors[id] = "This suggestion is out of date. Refresh to get a new one."
        } catch ReviewError.notPending {
            // Already accepted or dismissed somewhere else.
            await reloadPlan(proposal.planId)
            await reloadList(proposal.planId)
        } catch is CancellationError {
            return false
        } catch {
            errors[id] = Self.message(for: error)
        }
        return false
    }

    /// Removes the card. True when the server dismissed it, or it was already decided.
    func dismiss(_ id: String) async -> Bool {
        guard !working.contains(id), let proposal = proposals.first(where: { $0.id == id }) else { return false }
        working.insert(id)
        errors[id] = nil
        defer { working.remove(id) }
        do {
            try await service.dismiss(id: id)
            proposals.removeAll { $0.id == id }
            return true
        } catch ReviewError.notPending, ReviewError.stale {
            await reloadList(proposal.planId)
            return true
        } catch is CancellationError {
            return false
        } catch {
            errors[id] = Self.message(for: error)
            return false
        }
    }

    /// The Refresh on an out-of-date card: the engine looks at the plan as it is now, then the pending list is read again.
    func refresh(today: String) async {
        guard let planId, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // A refused or failed generate is not shown: the list below is what the server holds.
        _ = try? await service.generate(planId: planId, today: today, interview: nil)
        await reloadList(planId)
    }

    /// Goal and settings: re-runs the interview with `answers` and shows the result as a proposal. A sentence when it fails.
    func proposeInterviewRerun(planId: String, today: String, answers: Components.Schemas.InterviewAnswers) async -> String? {
        do {
            let made = try await service.generate(planId: planId, today: today, interview: answers)
            show(made + proposals.filter { old in !made.contains { $0.id == old.id } }, planId: planId)
            return nil
        } catch ReviewError.invalid {
            return "These answers don't give a plan for the weeks that are left. Try changing one."
        } catch is CancellationError {
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    // MARK: Reloading

    private func reloadPlan(_ planId: String) async {
        await plans.show(planId: planId)
    }

    private func reloadList(_ planId: String) async {
        if let fresh = try? await service.pending(planId: planId) { show(fresh, planId: planId) }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ReviewError.offline: "We couldn't reach the server. Check your connection and try again."
        case ReviewError.signedOut: "You've been signed out. Sign in again to change your plan."
        case ReviewError.notFound: "That suggestion is no longer there."
        default: "Something went wrong. Please try again."
        }
    }
}
