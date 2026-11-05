import APIClient
import Foundation
import Testing
@testable import RunningPlan

private func edit(_ key: String, _ update: Components.Schemas.SessionUpdate, id: String = syncSession, base: Int = 1) -> SyncOp {
    .sessionUpdate(key: key, id: id, baseRevision: base, update)
}

/// A server that holds each session at a revision and applies an edit made on that revision.
private final class MiniServer: @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [String: Int]
    private(set) var bases: [String: Int] = [:]

    init(_ revisions: [String: Int] = [syncSession: 1]) { self.revisions = revisions }

    func handle(_ ops: [SyncOp]) throws -> Components.Schemas.SyncResponse {
        try lock.withLock {
            var results: [String] = []
            for op in ops {
                let id = op.entity.id
                bases[op.idempotencyKey] = op.baseRevision
                let current = revisions[id] ?? 1
                if op.baseRevision == nil || op.baseRevision == current {
                    revisions[id] = op.baseRevision == nil ? 1 : current + 1
                    results.append(result(op.idempotencyKey, "applied", revision: revisions[id]))
                } else {
                    results.append(result(op.idempotencyKey, "conflict", server: sessionJSON(id, revision: current, title: "Theirs")))
                }
            }
            return try response(results: results)
        }
    }
}

@MainActor
struct OfflineSyncTests {
    @Test func twoOfflineEditsToOneSessionSyncWithoutAPrompt() async throws {
        let server = MiniServer()
        let (sync, _, service) = makeSync(service: FakeSyncService { _, ops in try server.handle(ops) })
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "One"), base: 1))
        sync.enqueue(edit("b", .init(notes: "Two"), base: 2))

        let outcome = await sync.run()

        #expect(outcome.applied == 2)
        #expect(sync.conflicts.isEmpty)
        #expect(sync.pendingCount == 0)
        #expect(service.calls.map(\.ops.count) == [1, 1])
        #expect(server.bases["b"] == 2)
    }

    @Test func aChainedEditIsSentOnTheRevisionTheServerGave() async throws {
        // The device guessed base 2 for the second edit, the server's first answer says 4.
        let service = FakeSyncService { _, ops in
            try response(results: [result(ops[0].idempotencyKey, "applied", revision: ops[0].idempotencyKey == "a" ? 4 : 5)])
        }
        let (sync, _, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "One"), base: 1))
        sync.enqueue(edit("b", .init(notes: "Two"), base: 2))
        _ = await sync.run()
        #expect(service.calls[1].ops.first?.baseRevision == 4)
    }

    @Test func aConflictAsksAndKeepMineResendsTheSameEditOnTheServersRevision() async throws {
        let server = MiniServer([syncSession: 5])
        let (sync, _, service) = makeSync(service: FakeSyncService { _, ops in try server.handle(ops) })
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine"), base: 1))

        _ = await sync.run()
        #expect(sync.conflicts.map(\.key) == ["a"])
        #expect(sync.pendingCount == 1)

        sync.keepMine(key: "a")
        let outcome = await sync.run()

        #expect(outcome.applied == 1)
        #expect(sync.hasPending == false)
        #expect(service.calls.last?.ops.first?.idempotencyKey == "a")
        #expect(service.calls.last?.ops.first?.baseRevision == 5)
    }

    @Test func useTheOtherVersionDropsOurEditAndShowsTheServersCopy() async throws {
        let server = MiniServer([syncSession: 5])
        let (sync, box, _) = makeSync(service: FakeSyncService { _, ops in try server.handle(ops) })
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine"), base: 1))
        sync.enqueue(edit("b", .init(notes: "Later"), base: 2))
        _ = await sync.run()

        sync.useServer(key: "a")

        #expect(sync.pendingCount == 0)
        #expect(sync.conflicts.isEmpty)
        #expect(localSession(box.plan)?.value2.title == "Theirs")
        #expect(localSession(box.plan)?.value1.revision == 5)
    }

    @Test func aConflictOnOneSessionDoesNotHoldBackAnother() async throws {
        let server = MiniServer([syncSession: 5, otherSession: 1])
        let (sync, _, _) = makeSync(service: FakeSyncService { _, ops in try server.handle(ops) })
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine"), id: syncSession, base: 1))
        sync.enqueue(edit("b", .init(title: "Other"), id: otherSession, base: 1))
        let outcome = await sync.run()
        #expect(outcome.applied == 1)
        #expect(sync.conflicts.map(\.key) == ["a"])
        #expect(sync.state.queue.operations.map(\.idempotencyKey) == ["a"])
    }

    @Test func aReplayedEditThatTheServerAlreadyHoldsIsNotAConflict() async throws {
        // A Worker crash after the update but before the key was recorded: the retry conflicts with our own edit.
        let service = FakeSyncService { _, ops in
            try response(results: [result(ops[0].idempotencyKey, "conflict", server: sessionJSON(revision: 2, title: "Mine"))])
        }
        let (sync, box, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine"), base: 1))

        let outcome = await sync.run()

        #expect(outcome.applied == 1)
        #expect(sync.conflicts.isEmpty)
        #expect(sync.pendingCount == 0)
        #expect(localSession(box.plan)?.value1.revision == 2)
    }

    @Test func aServerCopyThatDiffersIsStillAConflict() async throws {
        let service = FakeSyncService { _, ops in
            try response(results: [result(ops[0].idempotencyKey, "conflict", server: sessionJSON(revision: 2, title: "Someone else's"))])
        }
        let (sync, _, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine"), base: 1))
        _ = await sync.run()
        #expect(sync.conflicts.count == 1)
    }

    @Test func aSessionDeletedElsewhereStaysDeleted() async throws {
        let service = FakeSyncService { _, ops in
            try response(results: [result(ops[0].idempotencyKey, "conflict", server: sessionJSON(revision: 3, deleted: true))])
        }
        let (sync, box, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine"), base: 1))

        _ = await sync.run()

        #expect(sync.conflicts.isEmpty)
        #expect(sync.pendingCount == 0)
        #expect(localSession(box.plan) == nil)
        #expect(sync.notice?.contains("deleted") == true)
    }

    @Test func aTombstoneInThePullRemovesTheSession() async throws {
        let service = FakeSyncService { _, _ in try response(sessions: [sessionJSON(revision: 3, deleted: true)]) }
        let (sync, box, _) = makeSync(service: service)
        await sync.activate()
        _ = await sync.run()
        #expect(localSession(box.plan) == nil)
    }

    @Test func aDeletedPlanTakesItsSessionsAndQueuedEditsWithIt() async throws {
        let service = FakeSyncService { _, _ in try response(plans: [try planJSON(revision: 5, deleted: true)]) }
        let (sync, box, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine"), base: 1))
        sync.enqueue(.checkIn(key: "k", id: "ci", sessionId: otherSession, .init(when: .before, feel: 3)))

        let outcome = await sync.run()

        #expect(outcome.planDeleted)
        #expect(box.cleared)
        #expect(sync.pendingCount == 0)
    }

    @Test func aPulledChangeDoesNotOverwriteAnEditStillWaiting() async throws {
        let service = FakeSyncService { _, ops in
            // The first session is held for the user's choice; the pull carries the server's version of it.
            try response(results: ops.isEmpty ? [] : [result(ops[0].idempotencyKey, "conflict", server: sessionJSON(revision: 5, title: "Theirs"))], sessions: [sessionJSON(revision: 5, title: "Theirs")])
        }
        let (sync, box, _) = makeSync(service: service)
        await sync.activate()
        let current = try #require(localSession(box.plan))
        box.plan = SyncMerge.replace(session: SessionEditing.apply(.init(title: "Mine"), to: current, now: Date()), in: box.plan)
        sync.enqueue(edit("a", .init(title: "Mine"), base: 1))

        _ = await sync.run()

        #expect(localSession(box.plan)?.value2.title == "Mine")
    }

    @Test func aPullPagesUntilNothingIsLeft() async throws {
        let service = FakeSyncService { cursor, _ in
            cursor == nil ? try response(hasMore: true, cursor: "page1") : try response(sessions: [sessionJSON(otherSession, revision: 9, title: "New")], hasMore: false, cursor: "page2")
        }
        let (sync, box, _) = makeSync(service: service)
        await sync.activate()
        _ = await sync.run()
        #expect(service.calls.map(\.cursor) == [nil, "page1"])
        #expect(sync.state.cursor == "page2")
        #expect(localSession(box.plan, otherSession)?.value2.title == "New")
    }

    @Test func theQueueLoopsUntilTheServerHasAnsweredEverything() async throws {
        // The server's query budget lets it answer one operation per request.
        let service = FakeSyncService { _, ops in
            try response(results: [result(ops[0].idempotencyKey, "applied", revision: 2)])
        }
        let (sync, _, _) = makeSync(service: service)
        await sync.activate()
        let ids = [syncSession, otherSession, thirdSession]
        for (index, id) in ids.enumerated() { sync.enqueue(edit("k\(index)", .init(title: "T\(index)"), id: id)) }

        let outcome = await sync.run()

        #expect(outcome.applied == 3)
        #expect(sync.pendingCount == 0)
        #expect(service.calls.map(\.ops.count) == [3, 2, 1])
    }

    @Test func aServerThatAnswersNothingDoesNotLoopForever() async throws {
        let service = FakeSyncService { _, _ in try response() }
        let (sync, _, service2) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine")))
        let outcome = await sync.run()
        #expect(outcome.failed)
        #expect(service2.calls.count == 1)
        #expect(sync.pendingCount == 1)
    }

    @Test func offlineKeepsTheQueueForTheNextTrigger() async throws {
        let service = FakeSyncService { _, _ in throw SyncError.offline }
        let (sync, _, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine")))
        let outcome = await sync.run()
        #expect(outcome.offline)
        #expect(sync.isOffline)
        #expect(sync.pendingCount == 1)
    }

    @Test func signedOutKeepsTheQueue() async throws {
        let service = FakeSyncService { _, _ in throw SyncError.signedOut }
        let (sync, _, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine")))
        let outcome = await sync.run()
        #expect(outcome.signedOut)
        #expect(sync.pendingCount == 1)
    }

    @Test func aRefusedBatchIsRetriedOneEditAtATimeAndOnlyTheBadOneIsDropped() async throws {
        let service = FakeSyncService { _, ops in
            if ops.count > 1 || ops.first?.idempotencyKey == "bad" { throw SyncError.badRequest }
            return try response(results: [result(ops[0].idempotencyKey, "applied", revision: 2)])
        }
        let (sync, _, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("bad", .init(title: "x"), id: syncSession))
        sync.enqueue(edit("good", .init(title: "y"), id: otherSession))

        let outcome = await sync.run()

        #expect(outcome.applied == 1)
        #expect(sync.pendingCount == 0)
        #expect(sync.notice != nil)
    }

    @Test func aRejectedEditIsDroppedAndTheServersStateIsLoaded() async throws {
        let service = FakeSyncService { _, ops in try response(results: [result(ops[0].idempotencyKey, "rejected")]) }
        let (sync, _, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine")))
        let outcome = await sync.run()
        #expect(outcome.reload)
        #expect(sync.pendingCount == 0)
    }

    @Test func aDuplicateCountsAsApplied() async throws {
        let service = FakeSyncService { _, ops in try response(results: [result(ops[0].idempotencyKey, "duplicate", revision: 2)]) }
        let (sync, _, _) = makeSync(service: service)
        await sync.activate()
        sync.enqueue(edit("a", .init(title: "Mine")))
        _ = await sync.run()
        #expect(sync.pendingCount == 0)
    }

    @Test func aPlanPulledOntoADeviceWithoutOneIsLoadedInFull() async throws {
        let service = FakeSyncService { _, _ in try response(plans: [try planJSON()]) }
        let (sync, _, _) = makeSync(plan: nil, service: service)
        await sync.activate()
        #expect(await sync.run().reload)
    }

    @Test func theQueueAndCursorSurviveARelaunch() async throws {
        let store = MemoryOfflineStore()
        let first = makeSync(store: store, service: FakeSyncService { _, _ in throw SyncError.offline })
        await first.sync.activate()
        first.sync.cache(plan: first.box.plan)
        first.sync.enqueue(edit("a", .init(title: "Mine")))

        let second = makeSync(plan: nil, store: store)
        await second.sync.activate()

        #expect(second.sync.state.queue.operations.map(\.idempotencyKey) == ["a"])
        #expect(second.sync.cachedPlan != nil)
    }

    @Test func anotherAccountHasItsOwnQueue() async throws {
        let store = MemoryOfflineStore()
        let first = makeSync(store: store)
        await first.sync.activate()
        first.sync.enqueue(edit("a", .init(title: "Mine")))

        let other = OfflineSync(store: store, service: FakeSyncService(), scope: { "test|someone-else" })
        await other.activate()
        #expect(other.pendingCount == 0)
    }
}

struct ProposalSyncTests {
    private func proposal(_ id: String, base: Int, status: String = "pending", deleted: Bool = false) throws -> Components.Schemas.Proposal {
        try decode(Components.Schemas.Proposal.self, #"{"id":"\#(id)","planId":"\#(PlanFixture.planID)","baseContentRevision":\#(base),"kind":"adjustment","creator":{"type":"rules","version":"0.1.0"},"reason":"Missed","changes":[],"status":"\#(status)","createdAt":"2026-10-28T08:00:00.000Z","updatedAt":"2026-10-28T08:00:00.000Z","deletedAt":\#(deleted ? #""2026-10-29T08:00:00.000Z""# : "null")}"#)
    }

    private func plan(contentRevision: Int) throws -> Components.Schemas.Plan {
        try PlanFixture.detail().value1.with(contentRevision: contentRevision)
    }

    @Test func aPendingProposalBuiltOnAnOlderPlanRevisionGoesStale() throws {
        let merged = ProposalSync.merge([], with: [try proposal("p1", base: 2), try proposal("p2", base: 4)], plan: try plan(contentRevision: 4))
        #expect(merged.map(\.status) == [.stale, .pending])
    }

    @Test func aResolvedProposalStaysAsItWas() throws {
        let merged = ProposalSync.merge([], with: [try proposal("p1", base: 2, status: "accepted")], plan: try plan(contentRevision: 4))
        #expect(merged.map(\.status) == [.accepted])
    }

    @Test func aMovedPlanStalesProposalsAlreadyOnTheDevice() throws {
        let stored = [try proposal("p1", base: 4)]
        let merged = ProposalSync.merge(stored, with: [], plan: try plan(contentRevision: 5))
        #expect(merged.map(\.status) == [.stale])
        #expect(ProposalSync.pending(merged, for: PlanFixture.planID).isEmpty)
    }

    @Test func aTombstonedProposalIsDropped() throws {
        let stored = [try proposal("p1", base: 4)]
        let merged = ProposalSync.merge(stored, with: [try proposal("p1", base: 4, deleted: true)], plan: try plan(contentRevision: 4))
        #expect(merged.isEmpty)
    }
}

private extension Components.Schemas.Plan {
    func with(contentRevision: Int) -> Self {
        var copy = self
        copy.value3.contentRevision = contentRevision
        return copy
    }
}
