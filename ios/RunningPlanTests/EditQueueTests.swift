import APIClient
import Foundation
import Testing
@testable import RunningPlan

private func update(_ key: String, _ id: String = syncSession, base: Int = 1) -> SyncOp {
    .sessionUpdate(key: key, id: id, baseRevision: base, .init(title: key))
}

private func create(_ key: String, _ id: String) throws -> SyncOp {
    let content = try decode(Components.Schemas.SessionContent.self, #"{"date":"2026-10-29","type":"rest","title":"Rest day"}"#)
    return .sessionCreate(key: key, planId: PlanFixture.planID, .init(value1: content, value2: .init(id: id)))
}

struct EditQueueTests {
    @Test func editsKeepTheirOrder() {
        var queue = EditQueue()
        queue.enqueue(update("a", syncSession))
        queue.enqueue(update("b", otherSession))
        #expect(queue.operations.map(\.idempotencyKey) == ["a", "b"])
    }

    @Test func aRequestCarriesOneEditPerSession() {
        // A second edit of a session needs the revision the first produces, so it waits for the next request.
        var queue = EditQueue()
        queue.enqueue(update("a", syncSession, base: 1))
        queue.enqueue(update("b", syncSession, base: 2))
        queue.enqueue(update("c", otherSession, base: 1))
        #expect(queue.nextBatch().map(\.idempotencyKey) == ["a", "c"])
    }

    @Test func aSessionWaitingForTheUsersChoiceHoldsBackOnlyItself() {
        var queue = EditQueue()
        queue.enqueue(update("a", syncSession))
        queue.enqueue(update("b", otherSession))
        #expect(queue.nextBatch(blocked: [syncSession]).map(\.idempotencyKey) == ["b"])
    }

    @Test func aRequestHoldsAtMostTheLimit() {
        var queue = EditQueue()
        for index in 0..<5 { queue.enqueue(.checkIn(key: "k\(index)", id: "c\(index)", sessionId: syncSession, .init(when: .before, feel: 3))) }
        #expect(queue.nextBatch(limit: 3).count == 3)
    }

    @Test func theNextEditOfASessionTakesTheRevisionTheServerGave() {
        var queue = EditQueue()
        queue.enqueue(update("a", syncSession, base: 1))
        queue.enqueue(update("b", syncSession, base: 2))
        queue.remove(key: "a")
        queue.rebaseNext(of: .session(syncSession), to: 7)
        #expect(queue.operation(key: "b")?.baseRevision == 7)
    }

    @Test func aSessionCreatedAndDeletedBeforeSyncingNeverGoesToTheServer() throws {
        var queue = EditQueue()
        queue.enqueue(try create("c", otherSession))
        queue.enqueue(update("u", otherSession, base: 1))
        queue.enqueue(.checkIn(key: "k", id: "ci", sessionId: otherSession, .init(when: .before, feel: 3)))
        queue.enqueue(update("keep", syncSession))
        let outcome = queue.enqueue(.sessionDelete(key: "d", id: otherSession, baseRevision: 1))
        #expect(outcome == .cancelled)
        #expect(queue.operations.map(\.idempotencyKey) == ["keep"])
    }

    @Test func aCreateThatWasSentMayHaveBeenAppliedSoItsDeleteIsKept() throws {
        var queue = EditQueue()
        let op = try create("c", otherSession)
        queue.enqueue(op)
        queue.markAttempted([op])
        let outcome = queue.enqueue(.sessionDelete(key: "d", id: otherSession, baseRevision: 1))
        #expect(outcome == .queued)
        #expect(queue.operations.map(\.idempotencyKey) == ["c", "d"])
    }

    @Test func droppingASessionRemovesAllItsEditsAndNothingElse() {
        var queue = EditQueue()
        queue.enqueue(update("a", syncSession))
        queue.enqueue(update("b", syncSession, base: 2))
        queue.enqueue(update("c", otherSession))
        queue.drop(entity: .session(syncSession))
        #expect(queue.operations.map(\.idempotencyKey) == ["c"])
    }

    @Test func aDeletedPlansSessionsLoseTheirEditsAndCheckIns() {
        var queue = EditQueue()
        queue.enqueue(update("a", syncSession))
        queue.enqueue(.checkIn(key: "k", id: "ci", sessionId: syncSession, .init(when: .before, feel: 3)))
        queue.enqueue(update("c", thirdSession))
        queue.dropSessions([syncSession, otherSession])
        #expect(queue.operations.map(\.idempotencyKey) == ["c"])
    }

    @Test func keepMineSendsTheSameEditAgainOnTheServersRevision() {
        var queue = EditQueue()
        queue.enqueue(update("a", syncSession, base: 1))
        queue.rebase(key: "a", to: 5)
        #expect(queue.operation(key: "a")?.baseRevision == 5)
        #expect(queue.operation(key: "a")?.idempotencyKey == "a")
    }

    @Test func theQueueSurvivesBeingStored() throws {
        var queue = EditQueue()
        queue.enqueue(update("a"))
        queue.markAttempted(queue.operations)
        let data = try APIConfiguration.encoder.encode(queue)
        #expect(try APIConfiguration.decoder.decode(EditQueue.self, from: data) == queue)
    }
}

struct SessionEditingTests {
    private func intervals() throws -> Sess { try decode(Sess.self, sessionJSON(revision: 1, title: "Intervals", owner: "system")) }

    @Test func anEditBumpsTheRevisionAndHandsTheSessionToTheUser() throws {
        let next = SessionEditing.apply(.init(title: "Mine"), to: try intervals(), now: Date(timeIntervalSince1970: 0))
        #expect(next.value2.title == "Mine")
        #expect(next.value1.revision == 2)
        #expect(next.value2.owner == .user)
    }

    @Test func aStatusOnlyEditLeavesOwnershipAlone() throws {
        let next = SessionEditing.apply(.init(status: .done), to: try intervals(), now: Date())
        #expect(next.value2.status == .done)
        #expect(next.value2.owner == .system)
    }

    @Test func clearRemovesOptionalFields() throws {
        let next = SessionEditing.apply(.init(clear: [.title]), to: try intervals(), now: Date())
        #expect(next.value2.title == nil)
    }

    @Test func changingToAnotherKindOfSessionEmptiesTheSteps() throws {
        let start = try decode(Sess.self, #"{"id":"\#(syncSession)","planId":"\#(PlanFixture.planID)","revision":1,"updatedAt":"2026-10-28T08:00:00.000Z","deletedAt":null,"date":"2026-10-28","type":"easy","status":"planned","owner":"system","steps":[{"kind":"work","goal":{"type":"distance","value":5000},"target":{"type":"effort","effort":"easy"}}]}"#)
        let next = SessionEditing.apply(.init(_type: .strength), to: start, now: Date())
        #expect(next.value2.steps == [])
        let same = SessionEditing.apply(.init(_type: .tempo), to: start, now: Date())
        #expect(same.value2.steps?.count == 1)
    }

    @Test func aDeleteIsATombstoneOneRevisionOn() throws {
        let gone = SessionEditing.deleted(try intervals(), now: Date())
        #expect(gone.value1.deletedAt != nil)
        #expect(gone.value1.revision == 2)
    }

    @Test func aServerCopyThatHasTheEditIsSeenAsAlreadyApplied() throws {
        let server = try decode(Sess.self, sessionJSON(revision: 2, title: "Mine"))
        #expect(SessionEditing.reflects(.init(title: "Mine"), in: server))
        #expect(!SessionEditing.reflects(.init(title: "Mine too"), in: server))
        #expect(!SessionEditing.reflects(.init(title: "Mine", notes: "Hello"), in: server))
        #expect(!SessionEditing.reflects(.init(clear: [.title]), in: server))
    }
}
