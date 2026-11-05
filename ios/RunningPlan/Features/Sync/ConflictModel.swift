import APIClient
import Foundation

/// What the sync-conflict sheet says (docs/design-notes.md, "Sync conflict"): the session by name and the fields where
/// the two versions differ. Pure.
struct ConflictModel: Equatable, Identifiable {
    var id: String { key }

    struct Row: Equatable, Identifiable {
        let field: String
        let mine: String
        let theirs: String
        var id: String { field }
    }

    let key: String
    let title: String
    let rows: [Row]

    init?(conflict: SyncConflict, queue: EditQueue) {
        guard case .Session(let server) = conflict.server, let op = queue.operation(key: conflict.key) else { return nil }
        key = conflict.key
        let content = server.value2
        title = content.title ?? "Session on \(content.date)"
        switch op {
        case .session_period_update(let update):
            rows = Self.rows(for: update.data, server: content)
        case .session_period_delete:
            rows = [Row(field: "Session", mine: "Delete it", theirs: "Keep it, as changed")]
        default:
            rows = []
        }
    }

    private static func rows(for update: Components.Schemas.SessionUpdate, server: Components.Schemas.SessionContent) -> [Row] {
        var rows: [Row] = []
        func add(_ field: String, _ mine: String, _ theirs: String) {
            if mine != theirs { rows.append(Row(field: field, mine: mine, theirs: theirs)) }
        }
        if let date = update.date { add("Day", date, server.date) }
        if let type = update._type { add("Type", type.rawValue.capitalized, server._type.rawValue.capitalized) }
        if let title = update.title { add("Title", title, server.title ?? "None") }
        if let status = update.status { add("Status", status.rawValue.capitalized, (server.status ?? .planned).rawValue.capitalized) }
        if let key = update.key { add("Key session", key ? "Yes" : "No", (server.key ?? false) ? "Yes" : "No") }
        if let notes = update.notes { add("Notes", notes, server.notes ?? "None") }
        if let steps = update.steps, steps != (server.steps ?? []) {
            rows.append(Row(field: "Steps", mine: count(steps.count), theirs: count((server.steps ?? []).count)))
        }
        for field in update.clear ?? [] {
            switch field {
            case .title: add("Title", "None", server.title ?? "None")
            case .notes: add("Notes", "None", server.notes ?? "None")
            case .custom: add("Details", "None", server.custom == nil ? "None" : "Cross-training details")
            }
        }
        if rows.isEmpty { rows.append(Row(field: "Session", mine: "Your version", theirs: "The other version")) }
        return rows
    }

    private static func count(_ n: Int) -> String { n == 1 ? "1 step" : "\(n) steps" }
}
