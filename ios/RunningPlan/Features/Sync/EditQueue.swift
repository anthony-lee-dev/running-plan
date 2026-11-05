import APIClient
import Foundation

/// The offline edit queue (design §8.2): every change is appended with its idempotency key and base revision, and
/// leaves only when the server has answered it. Pure and Codable, so it is stored as it is.
struct EditQueue: Codable, Equatable, Sendable {
    private(set) var operations: [SyncOp] = []
    /// Keys of operations that went out in a request (the answer may have been lost, so the server may have applied them).
    private(set) var attempted: Set<String> = []

    var isEmpty: Bool { operations.isEmpty }
    var count: Int { operations.count }

    enum Outcome: Equatable {
        case queued
        /// A session created and deleted before either synced: both, and its check-ins, were dropped.
        case cancelled
    }

    @discardableResult
    mutating func enqueue(_ op: SyncOp) -> Outcome {
        if case .session_period_delete(let delete) = op,
           let create = operations.first(where: { if case .session_period_create(let c) = $0 { return c.id == delete.id }; return false }),
           !attempted.contains(create.idempotencyKey) {
            // The server never saw the session (no request carried its create), so nothing needs to be undone there.
            operations.removeAll { $0.entity == .session(delete.id) || $0.checkInSessionId == delete.id }
            return .cancelled
        }
        operations.append(op)
        return .queued
    }

    func contains(key: String) -> Bool { operations.contains { $0.idempotencyKey == key } }
    func operation(key: String) -> SyncOp? { operations.first { $0.idempotencyKey == key } }

    /// Entities with an edit still waiting, so a pull does not overwrite them.
    var pendingEntities: Set<String> {
        Set(operations.compactMap { op in
            if case .checkIn = op.entity { return nil }
            return op.entity.id
        })
    }

    /// The next request: queue order, at most one edit per session or plan (a later one needs the revision the first
    /// produces, so it goes in the next request), skipping entities that wait for the user's choice.
    func nextBatch(blocked: Set<String> = [], limit: Int = 200) -> [SyncOp] {
        var seen: Set<SyncEntity> = []
        var batch: [SyncOp] = []
        for op in operations {
            if batch.count >= limit { break }
            let entity = op.entity
            if case .checkIn = entity {} else {
                if blocked.contains(entity.id) || seen.contains(entity) { continue }
                seen.insert(entity)
            }
            batch.append(op)
        }
        return batch
    }

    mutating func markAttempted(_ ops: [SyncOp]) {
        attempted.formUnion(ops.map(\.idempotencyKey))
    }

    mutating func remove(key: String) {
        operations.removeAll { $0.idempotencyKey == key }
        attempted.remove(key)
    }

    /// Drops every edit of one entity (the user took the other version, or the entity is gone).
    mutating func drop(entity: SyncEntity) {
        let keys = operations.filter { $0.entity == entity }.map(\.idempotencyKey)
        operations.removeAll { $0.entity == entity }
        attempted.subtract(keys)
    }

    /// The plan was deleted elsewhere and took its sessions: their edits and check-ins have nothing to apply to.
    mutating func dropSessions(_ ids: Set<String>) {
        let keys = operations.filter { op in
            if case .session = op.entity, ids.contains(op.entity.id) { return true }
            return op.checkInSessionId.map(ids.contains) ?? false
        }.map(\.idempotencyKey)
        operations.removeAll { keys.contains($0.idempotencyKey) }
        attempted.subtract(keys)
    }

    /// The server is now at `revision` for this entity: the next waiting edit of it is made on that revision.
    mutating func rebaseNext(of entity: SyncEntity, to revision: Int) {
        guard let index = operations.firstIndex(where: { $0.entity == entity && $0.baseRevision != nil }) else { return }
        operations[index] = operations[index].rebased(to: revision)
    }

    /// "Keep mine": the edit is sent again under its own key on the server's revision.
    mutating func rebase(key: String, to revision: Int) {
        guard let index = operations.firstIndex(where: { $0.idempotencyKey == key }) else { return }
        operations[index] = operations[index].rebased(to: revision)
        attempted.remove(key)
    }
}
