import APIClient
import Foundation

typealias SyncOp = Components.Schemas.SyncOperation

/// What an operation edits. Sessions and plans are the things two devices can change at once; a check-in is only ever created.
enum SyncEntity: Hashable, Sendable {
    case plan(String)
    case session(String)
    case checkIn(String)

    var id: String {
        switch self {
        case .plan(let id), .session(let id), .checkIn(let id): id
        }
    }
}

extension Components.Schemas.SyncOperation {
    var idempotencyKey: String {
        switch self {
        case .plan_period_create(let op): op.idempotencyKey
        case .plan_period_update(let op): op.idempotencyKey
        case .plan_period_delete(let op): op.idempotencyKey
        case .session_period_create(let op): op.idempotencyKey
        case .session_period_update(let op): op.idempotencyKey
        case .session_period_delete(let op): op.idempotencyKey
        case .checkin_period_create(let op): op.idempotencyKey
        }
    }

    var entity: SyncEntity {
        switch self {
        case .plan_period_create(let op): .plan(op.id)
        case .plan_period_update(let op): .plan(op.id)
        case .plan_period_delete(let op): .plan(op.id)
        case .session_period_create(let op): .session(op.id)
        case .session_period_update(let op): .session(op.id)
        case .session_period_delete(let op): .session(op.id)
        case .checkin_period_create(let op): .checkIn(op.id)
        }
    }

    /// The session a check-in belongs to, so a session created and deleted before it ever synced takes its check-ins along.
    var checkInSessionId: String? {
        if case .checkin_period_create(let op) = self { return op.sessionId }
        return nil
    }

    /// The revision the edit was made on; nil for a create.
    var baseRevision: Int? {
        switch self {
        case .plan_period_update(let op): op.baseRevision
        case .plan_period_delete(let op): op.baseRevision
        case .session_period_update(let op): op.baseRevision
        case .session_period_delete(let op): op.baseRevision
        case .plan_period_create, .session_period_create, .checkin_period_create: nil
        }
    }

    /// The same edit made on another revision (an update or delete; a create is returned unchanged).
    func rebased(to revision: Int) -> SyncOp {
        switch self {
        case .plan_period_update(var op): op.baseRevision = revision; return .plan_period_update(op)
        case .plan_period_delete(var op): op.baseRevision = revision; return .plan_period_delete(op)
        case .session_period_update(var op): op.baseRevision = revision; return .session_period_update(op)
        case .session_period_delete(var op): op.baseRevision = revision; return .session_period_delete(op)
        case .plan_period_create, .session_period_create, .checkin_period_create: return self
        }
    }

    static func sessionUpdate(key: String, id: String, baseRevision: Int, _ data: Components.Schemas.SessionUpdate) -> SyncOp {
        .session_period_update(.init(idempotencyKey: key, kind: .session_period_update, id: id, baseRevision: baseRevision, data: data))
    }

    static func sessionCreate(key: String, planId: String, _ create: Components.Schemas.SessionCreate) -> SyncOp {
        .session_period_create(.init(idempotencyKey: key, kind: .session_period_create, id: create.value2.id, planId: planId, data: .init(value1: create.value1)))
    }

    static func sessionDelete(key: String, id: String, baseRevision: Int) -> SyncOp {
        .session_period_delete(.init(idempotencyKey: key, kind: .session_period_delete, id: id, baseRevision: baseRevision))
    }

    static func checkIn(key: String, id: String, sessionId: String, _ fields: Components.Schemas.CheckInFields) -> SyncOp {
        .checkin_period_create(.init(idempotencyKey: key, kind: .checkin_period_create, id: id, sessionId: sessionId, data: .init(value1: fields)))
    }
}

extension Components.Schemas.CheckInFields {
    static func before(_ feeling: BeforeFeeling) -> Self {
        .init(when: .before, feel: feeling.feel)
    }

    static func after(_ answer: AfterCheckIn) -> Self {
        .init(when: .after, feel: answer.feeling.feel, effortFelt: answer.feeling.effortFelt, pain: answer.pain)
    }
}
