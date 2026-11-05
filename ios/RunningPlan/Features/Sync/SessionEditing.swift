import APIClient
import Foundation

/// The on-device copy of an edit made offline. It mirrors `applySessionUpdate` in `api/src/domain/session-edit.ts`
/// (change both together), so the screens show what the server will hold once the edit syncs.
enum SessionEditing {
    typealias Session = Components.Schemas.Session
    typealias Update = Components.Schemas.SessionUpdate

    private static func kind(_ type: Components.Schemas.SessionType) -> Int {
        switch type {
        case .custom: 1
        case .strength: 2
        default: 0
        }
    }

    /// Only the status changed: the engine keeps ownership of the session.
    static func isStatusOnly(_ update: Update) -> Bool {
        update.status != nil && update.date == nil && update._type == nil && update.title == nil && update.key == nil
            && update.steps == nil && update.custom == nil && update.notes == nil && update.clear == nil
    }

    static func content(_ content: Components.Schemas.SessionContent, applying update: Update, markUser: Bool) -> Components.Schemas.SessionContent {
        var next = content
        if let date = update.date { next.date = date }
        if let type = update._type { next._type = type }
        if let title = update.title { next.title = title }
        if let key = update.key { next.key = key }
        if let status = update.status { next.status = .init(rawValue: status.rawValue) }
        if let notes = update.notes { next.notes = notes }
        if let custom = update.custom { next.custom = custom }
        if let steps = update.steps {
            next.steps = steps
        } else if kind(next._type) != kind(content._type) {
            next.steps = []
        }
        if next._type != .custom { next.custom = nil }
        for field in update.clear ?? [] {
            switch field {
            case .title: next.title = nil
            case .notes: next.notes = nil
            case .custom: next.custom = nil
            }
        }
        if markUser { next.owner = .user }
        return next
    }

    /// The session after `update`, one revision on, as the server will have it.
    static func apply(_ update: Update, to session: Session, now: Date) -> Session {
        var next = session
        next.value2 = content(session.value2, applying: update, markUser: !isStatusOnly(update))
        next.value1.revision = session.value1.revision + 1
        next.value1.updatedAt = now
        return next
    }

    static func created(planId: String, _ create: Components.Schemas.SessionCreate, now: Date) -> Session {
        var content = create.value1
        content.status = content.status ?? .planned
        content.owner = content.owner ?? .system
        return Session(
            value1: .init(id: create.value2.id, revision: 1, updatedAt: now, deletedAt: nil),
            value2: content,
            value3: .init(planId: planId)
        )
    }

    /// A tombstone, as the server's delete answers.
    static func deleted(_ session: Session, now: Date) -> Session {
        var next = session
        next.value1.revision = session.value1.revision + 1
        next.value1.updatedAt = now
        next.value1.deletedAt = now
        return next
    }

    /// The server already holds what `update` asks for: every field it set matches and every field it cleared is gone.
    /// This is how a replay after a crash looks (the edit was applied, the answer never recorded), and needs no prompt.
    /// Ownership is left out because it follows from the edit.
    static func reflects(_ update: Update, in server: Session) -> Bool {
        let c = server.value2
        if let date = update.date, c.date != date { return false }
        if let type = update._type, c._type != type { return false }
        if let title = update.title, c.title != title { return false }
        if let key = update.key, c.key != key { return false }
        if let status = update.status, c.status?.rawValue != status.rawValue { return false }
        if let notes = update.notes, c.notes != notes { return false }
        if let custom = update.custom, c.custom != custom { return false }
        if let steps = update.steps, (c.steps ?? []) != steps { return false }
        for field in update.clear ?? [] {
            switch field {
            case .title where c.title != nil: return false
            case .notes where c.notes != nil: return false
            case .custom where c.custom != nil: return false
            default: break
            }
        }
        return true
    }
}
