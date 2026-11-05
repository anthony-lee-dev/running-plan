import APIClient
import Foundation

/// Puts a pull's changes into the plan on the device. Pure.
enum SyncMerge {
    typealias Detail = Components.Schemas.PlanDetail

    struct Result: Equatable {
        var plan: Detail?
        /// The plan on screen arrived as a tombstone.
        var planDeleted = false
        /// There was no plan on screen and the pull carries a live one: load it in full (the pull has no warnings).
        var foundPlanId: String?
    }

    /// - Parameter pending: ids of plans and sessions with an edit still queued or awaiting the user's choice; the
    ///   device's copy of those stays (the server's version arrives once the edit has been sent).
    static func apply(
        plans: [Components.Schemas.Plan], sessions: [Components.Schemas.Session],
        to plan: Detail?, pending: Set<String>
    ) -> Result {
        guard var detail = plan else {
            return Result(plan: nil, foundPlanId: plans.last { $0.value1.deletedAt == nil }?.value1.id)
        }
        let id = detail.value1.value1.id
        for change in plans where change.value1.id == id {
            // A deleted plan takes its sessions with it: the server does not tombstone them one by one.
            if change.value1.deletedAt != nil { return Result(plan: nil, planDeleted: true) }
            if !pending.contains(id) { detail.value1 = change }
        }
        for change in sessions where change.value3.planId == id && !pending.contains(change.value1.id) {
            let index = detail.value2.sessions.firstIndex { $0.value1.id == change.value1.id }
            if change.value1.deletedAt != nil {
                if let index { detail.value2.sessions.remove(at: index) }
            } else if let index {
                detail.value2.sessions[index] = change
            } else {
                detail.value2.sessions.append(change)
            }
        }
        return Result(plan: detail)
    }

    /// The server acknowledged an edit and gave the revision it now holds: ours keeps its content and takes the number.
    static func settle(sessionId: String, revision: Int, in plan: Detail?) -> Detail? {
        guard var detail = plan, let index = detail.value2.sessions.firstIndex(where: { $0.value1.id == sessionId }) else { return plan }
        detail.value2.sessions[index].value1.revision = revision
        return detail
    }

    static func replace(session: Components.Schemas.Session, in plan: Detail?) -> Detail? {
        guard var detail = plan else { return plan }
        if let index = detail.value2.sessions.firstIndex(where: { $0.value1.id == session.value1.id }) {
            if session.value1.deletedAt != nil { detail.value2.sessions.remove(at: index) } else { detail.value2.sessions[index] = session }
        } else if session.value1.deletedAt == nil, session.value3.planId == detail.value1.value1.id {
            detail.value2.sessions.append(session)
        }
        return detail
    }

    static func remove(sessionId: String, from plan: Detail?) -> Detail? {
        guard var detail = plan else { return plan }
        detail.value2.sessions.removeAll { $0.value1.id == sessionId }
        return detail
    }
}

/// Proposals that came with a pull (none until the proposals endpoints exist, issue #70).
enum ProposalSync {
    typealias Proposal = Components.Schemas.Proposal

    /// Replaces by id, drops tombstones, and marks pending proposals stale when the plan moved on.
    static func merge(_ existing: [Proposal], with incoming: [Proposal], plan: Components.Schemas.Plan?) -> [Proposal] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for proposal in incoming {
            if proposal.deletedAt != nil { byId[proposal.id] = nil } else { byId[proposal.id] = proposal }
        }
        let merged = byId.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return markStale(merged, plan: plan)
    }

    /// A pending proposal was built on a plan revision that has moved: it can no longer be applied as shown.
    static func markStale(_ proposals: [Proposal], plan: Components.Schemas.Plan?) -> [Proposal] {
        guard let plan else { return proposals }
        return proposals.map { proposal in
            guard proposal.planId == plan.value1.id, proposal.status == .pending, proposal.baseContentRevision != plan.value3.contentRevision else { return proposal }
            var stale = proposal
            stale.status = .stale
            return stale
        }
    }

    static func pending(_ proposals: [Proposal], for planId: String) -> [Proposal] {
        proposals.filter { $0.planId == planId && $0.status == .pending }
    }
}
