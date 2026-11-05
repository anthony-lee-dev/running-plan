import APIClient
import Foundation
import Observation

/// The offline edit queue and its sync (design §8.2). Edits are appended with an idempotency key and base revision;
/// when online the queue is pushed, then changes since the cursor are pulled. Conflicts are per session by revision:
/// the user keeps theirs or takes the other version. Deleted things stay deleted (tombstones).
@MainActor
@Observable
final class OfflineSync {
    typealias Detail = Components.Schemas.PlanDetail

    struct Outcome: Equatable {
        /// Edits the server accepted.
        var applied = 0
        /// The plan on screen differs from the server's in ways the pull does not carry (warnings, a plan found, a
        /// rejected edit): load it again.
        var reload = false
        var planDeleted = false
        var offline = false
        var signedOut = false
        var failed = false
    }

    private(set) var state = OfflineState()
    /// A sentence about something sync did that the user should hear (a change dropped, a session deleted elsewhere).
    private(set) var notice: String?
    /// The last attempt could not reach the server.
    private(set) var isOffline = false

    private let store: OfflineStoring
    private let service: SyncServing
    private let scopeProvider: @Sendable () async -> String?
    private let clock: @Sendable () -> Date
    private var scope: String?
    private var running = false
    private var rerun = false

    /// The plan on screen, read and written by `PlanStore`.
    var read: @MainActor () -> Detail? = { nil }
    var write: @MainActor (Detail) -> Void = { _ in }
    /// The plan is gone (deleted on another device).
    var clear: @MainActor () -> Void = {}

    init(store: OfflineStoring, service: SyncServing, scope: @escaping @Sendable () async -> String?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.service = service
        scopeProvider = scope
        self.clock = clock
    }

    var now: Date { clock() }
    var pendingCount: Int { state.queue.count }
    var hasPending: Bool { !state.queue.isEmpty || !state.conflicts.isEmpty }
    /// Edits the server has not seen and that are not waiting for the user's choice.
    var hasSendable: Bool { !state.queue.nextBatch(blocked: blockedEntities(), limit: 1).isEmpty }
    var conflicts: [SyncConflict] { state.conflicts }
    var cachedPlan: Detail? { state.plan }
    var proposals: [Components.Schemas.Proposal] { state.proposals }

    static func newKey() -> String { UUID().uuidString.lowercased() }

    // MARK: Storage

    /// Loads what this account left on the device (a different API host or account has its own queue).
    func activate() async {
        let next = await scopeProvider()
        guard next != scope else { return }
        scope = next
        state = next.flatMap { store.load(scope: $0) } ?? OfflineState()
        isOffline = false
    }

    private func persist() {
        if let scope { store.save(state, scope: scope) }
    }

    func cache(plan: Detail?) {
        guard state.plan != plan else { return }
        state.plan = plan
        persist()
    }

    func dismissNotice() { notice = nil }

    /// Writes the edit to disk before anything reports it saved.
    @discardableResult
    func enqueue(_ op: SyncOp) -> EditQueue.Outcome {
        let outcome = state.queue.enqueue(op)
        persist()
        return outcome
    }

    // MARK: Conflicts

    /// "Keep mine": the edit is sent again, under its own key, on the server's revision.
    func keepMine(key: String) {
        guard let conflict = state.conflicts.first(where: { $0.key == key }), case .Session(let server) = conflict.server else { return }
        state.queue.rebase(key: key, to: server.value1.revision)
        state.conflicts.removeAll { $0.key == key }
        persist()
    }

    /// "Use the other version": our queued edits to that session are dropped and the server's copy is shown.
    func useServer(key: String) {
        guard let conflict = state.conflicts.first(where: { $0.key == key }) else { return }
        if case .Session(let server) = conflict.server {
            state.queue.drop(entity: .session(server.value1.id))
            state.conflicts.removeAll { $0.server.sessionId == server.value1.id }
            if let plan = SyncMerge.replace(session: server, in: read()) { write(plan) }
        } else {
            state.conflicts.removeAll { $0.key == key }
            state.queue.remove(key: key)
        }
        state.plan = read()
        persist()
    }

    // MARK: Running

    /// Pushes the queue until the server has answered every operation, then pulls until nothing is left, merging each
    /// page into the plan on screen. Offline or signed out it stops and keeps the queue for the next trigger.
    func run() async -> Outcome {
        if running {
            rerun = true
            return Outcome()
        }
        running = true
        defer { running = false }
        var total = Outcome()
        repeat {
            rerun = false
            let outcome = await pass()
            total.applied += outcome.applied
            total.reload = total.reload || outcome.reload
            total.planDeleted = total.planDeleted || outcome.planDeleted
            total.offline = outcome.offline
            total.signedOut = outcome.signedOut
            total.failed = outcome.failed
            if outcome.offline || outcome.signedOut { break }
        } while rerun
        isOffline = total.offline
        return total
    }

    private func blockedEntities() -> Set<String> {
        Set(state.conflicts.compactMap { state.queue.operation(key: $0.key)?.entity.id })
    }

    private func pass() async -> Outcome {
        var outcome = Outcome()
        var singly = false
        for _ in 0..<80 {
            let batch = state.queue.nextBatch(blocked: blockedEntities(), limit: singly ? 1 : 200)
            state.queue.markAttempted(batch)
            persist()
            let response: Components.Schemas.SyncResponse
            do {
                response = try await service.sync(cursor: state.cursor, operations: batch)
            } catch SyncError.offline {
                outcome.offline = true
                return outcome
            } catch SyncError.signedOut {
                outcome.signedOut = true
                return outcome
            } catch is CancellationError {
                return outcome
            } catch where error as? SyncError == .badRequest || error as? SyncError == .tooLarge {
                if batch.count > 1 {
                    singly = true
                    continue
                }
                guard let op = batch.first else {
                    outcome.failed = true
                    return outcome
                }
                // One operation the server cannot take; stopping would hold up everything behind it.
                state.queue.remove(key: op.idempotencyKey)
                notice = "One of your changes couldn't be saved and was dropped."
                outcome.reload = true
                persist()
                continue
            } catch {
                outcome.failed = true
                return outcome
            }

            for result in response.results {
                guard let op = batch.first(where: { $0.idempotencyKey == result.idempotencyKey }) else { continue }
                handle(result, for: op, &outcome)
            }
            merge(response.changes, &outcome)
            state.cursor = response.cursor
            persist()

            let unanswered = response.results.count < batch.count
            let more = !state.queue.nextBatch(blocked: blockedEntities(), limit: 1).isEmpty
            if !batch.isEmpty, response.results.isEmpty, !response.hasMore { outcome.failed = true; return outcome }
            if !(response.hasMore || unanswered || more) { return outcome }
        }
        outcome.failed = true
        return outcome
    }

    private func handle(_ result: Components.Schemas.SyncResult, for op: SyncOp, _ outcome: inout Outcome) {
        let key = op.idempotencyKey
        switch result.status {
        case .applied, .duplicate:
            state.queue.remove(key: key)
            outcome.applied += 1
            if let revision = result.revision, case .session = op.entity {
                state.queue.rebaseNext(of: op.entity, to: revision)
                if let plan = SyncMerge.settle(sessionId: op.entity.id, revision: revision, in: read()) { write(plan) }
            }
        case .rejected:
            // The server will not take it, now or later: show the server's state instead.
            state.queue.remove(key: key)
            outcome.reload = true
            notice = "One of your changes couldn't be saved, so we've shown what's on the server."
        case .conflict:
            conflict(result.server, for: op, &outcome)
        }
    }

    private func conflict(_ server: Components.Schemas.SyncResult.serverPayload?, for op: SyncOp, _ outcome: inout Outcome) {
        let key = op.idempotencyKey
        guard case .Session(let session)? = server else {
            // No server copy, or a plan conflict (no screen edits a plan offline): take the server's state.
            state.queue.remove(key: key)
            outcome.reload = true
            return
        }
        let id = session.value1.id
        if session.value1.deletedAt != nil, case .session_period_delete = op {
            // Our own delete, applied before a crash lost the record of it: done, and nothing to tell the user.
            state.queue.drop(entity: .session(id))
            outcome.applied += 1
            return
        }
        if session.value1.deletedAt != nil {
            // Deleted elsewhere: it stays deleted (§8.2), so there is nothing to keep.
            state.queue.drop(entity: .session(id))
            if let plan = SyncMerge.remove(sessionId: id, from: read()) { write(plan) }
            notice = "A session you changed was deleted on another device."
            return
        }
        if case .session_period_update(let update) = op, SessionEditing.reflects(update.data, in: session) {
            // Our own edit, applied before a crash lost the record of it: already done, no question to ask.
            state.queue.remove(key: key)
            state.queue.rebaseNext(of: op.entity, to: session.value1.revision)
            if let plan = SyncMerge.settle(sessionId: id, revision: session.value1.revision, in: read()) { write(plan) }
            outcome.applied += 1
            return
        }
        if !state.conflicts.contains(where: { $0.key == key }) {
            state.conflicts.append(SyncConflict(key: key, server: .Session(session)))
        }
    }

    private func merge(_ changes: Components.Schemas.SyncResponse.changesPayload, _ outcome: inout Outcome) {
        let pending = state.queue.pendingEntities
        let before = read()
        let merged = SyncMerge.apply(plans: changes.plans, sessions: changes.sessions, to: before, pending: pending)
        if merged.planDeleted {
            let ids = Set((before?.value2.sessions ?? []).map(\.value1.id))
            state.queue.dropSessions(ids)
            state.conflicts.removeAll { state.queue.operation(key: $0.key) == nil }
            clear()
            outcome.planDeleted = true
        } else if let plan = merged.plan, plan != before {
            write(plan)
        }
        if merged.foundPlan { outcome.reload = true }
        state.plan = read()
        state.proposals = ProposalSync.merge(state.proposals, with: changes.proposals, plan: state.plan?.value1)
    }
}

extension Components.Schemas.SyncResult.serverPayload {
    var sessionId: String? {
        if case .Session(let session) = self { return session.value1.id }
        return nil
    }
}
