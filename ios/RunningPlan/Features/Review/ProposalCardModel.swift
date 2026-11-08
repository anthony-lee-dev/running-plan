import APIClient
import Foundation

/// How one proposal reads on its card (DK-Review, docs/design-notes.md "Proposal card"): a title, the engine's one-line
/// reason, and before to after rows. Pure and unit-tested. The API has only a `reason`, so the title is worked out from
/// the changes. Whether it is stale is compared live with the plan's content revision, never stored.
struct ProposalCardModel: Equatable, Identifiable {
    typealias Proposal = Components.Schemas.Proposal
    typealias Content = Components.Schemas.SessionContent

    struct Row: Equatable, Identifiable {
        let id: String
        /// "Sat, Oct 31".
        let day: String
        /// `YYYY-MM-DD`, for ordering.
        let date: String
        /// The session's name, for a locked row.
        let label: String
        let before: String?
        /// Nil for a session that is dropped.
        let after: String?
        let dropped: Bool
        let added: Bool
        /// A user-owned session: left alone unless the user includes their own sessions.
        let locked: Bool
        /// "Sunday cycling is yours".
        let lockedText: String
    }

    /// More rows than this fold into "and N more".
    static let maxRows = 5

    let id: String
    let title: String
    let reason: String
    let urgent: Bool
    let isRerun: Bool
    let rows: [Row]
    let moreCount: Int
    /// "and 40 more (25 added, 15 dropped)"; the counts only when both kinds are folded away.
    let moreText: String
    let lockedCount: Int
    let stale: Bool
    /// An interview re-run's new goal and length ("10K on Jan 10 · 12 weeks").
    let planNote: String?
    private let appliedCount: Int
    private let changeCount: Int

    init(proposal: Proposal, planContentRevision: Int?) {
        id = proposal.id
        reason = proposal.reason
        urgent = proposal.urgent ?? false
        isRerun = proposal.kind == .interview_rerun
        stale = proposal.status == .stale || planContentRevision.map { $0 != proposal.baseContentRevision } ?? false
        // By date (a drop before its replacement), so the rows shown mix drops and additions.
        let all = Self.byDate(proposal.changes.map(Self.row))
        rows = Array(all.prefix(Self.maxRows))
        moreCount = max(0, all.count - Self.maxRows)
        let folded = all.dropFirst(Self.maxRows)
        let (added, dropped) = (folded.filter(\.added).count, folded.filter(\.dropped).count)
        moreText = added > 0 && dropped > 0 ? "and \(moreCount) more (\(added) added, \(dropped) dropped)" : "and \(moreCount) more"
        lockedCount = all.filter(\.locked).count
        appliedCount = all.filter { !$0.locked }.count
        changeCount = all.count
        title = isRerun ? "Re-plan the weeks ahead" : Self.title(for: proposal.changes)
        planNote = proposal.planChanges.flatMap(Self.note)
    }

    /// Accepting would apply nothing: every change is to a session of the user's, and they have not included them.
    func changesNothing(includeUserOwned: Bool) -> Bool {
        !includeUserOwned && changeCount > 0 && appliedCount == 0
    }

    // MARK: Rows

    private typealias SortKey = (date: String, added: Int, index: Int)

    /// Stable sort by date, a drop before the addition on the same day.
    private static func byDate(_ rows: [Row]) -> [Row] {
        var keyed: [(key: SortKey, row: Row)] = []
        for (index, row) in rows.enumerated() {
            let key: SortKey = (row.date, row.added ? 1 : 0, index)
            keyed.append((key: key, row: row))
        }
        keyed.sort { (a: (key: SortKey, row: Row), b: (key: SortKey, row: Row)) -> Bool in
            if a.key.date != b.key.date { return a.key.date < b.key.date }
            if a.key.added != b.key.added { return a.key.added < b.key.added }
            return a.key.index < b.key.index
        }
        return keyed.map(\.row)
    }

    private static func row(_ change: Components.Schemas.ProposalChange) -> Row {
        let content = change.after ?? change.before
        let date = content?.date ?? ""
        let retypes = change.before != nil && change.after != nil && change.before?._type != change.after?._type
        let name = change.before.map(sessionName) ?? change.after.map(sessionName) ?? "Session"
        let weekday = NextModel.weekday(date)
        func text(_ session: Content?) -> String? {
            guard let session else { return nil }
            return retypes ? "\(sessionName(session)) · \(value(session))" : value(session)
        }
        return Row(
            id: change.sessionId ?? date + name,
            day: dayLabel(date), date: date, label: name, before: text(change.before), after: change.op == .delete ? nil : text(change.after),
            dropped: change.op == .delete, added: change.op == .create, locked: change.userOwned ?? false,
            lockedText: "\(weekday) \(name.lowercased()) is yours"
        )
    }

    /// "8 km" for a run, "45 min" for time-based sessions.
    private static func value(_ session: Content) -> String {
        let metres = PlanPreview.metres(of: session)
        if metres > 0 { return "\(PlanPreview.kilometres(metres / 1000)) km" }
        return "\(Int((SessionSummary.estimatedSeconds(session) / 60).rounded())) min"
    }

    private static func sessionName(_ session: Content) -> String {
        session.title ?? kind(session)
    }

    /// "long run", "easy run", "tempo run", "intervals", "strength" for a sentence.
    private static func kind(_ session: Content) -> String {
        switch session._type {
        case .easy: "easy run"
        case .long: "long run"
        case .tempo: "tempo run"
        case .intervals: "intervals"
        case .strength: "strength"
        case .rest: "rest day"
        case .custom: (session.title ?? "own session").lowercased()
        }
    }

    // MARK: Title

    private static func title(for changes: [Components.Schemas.ProposalChange]) -> String {
        let live = changes.filter { !($0.userOwned ?? false) }
        let counted = live.isEmpty ? changes : live
        if counted.count == 1, let change = counted.first {
            let session = change.before ?? change.after
            let weekday = NextModel.weekday(session?.date ?? "")
            let what = session.map(kind) ?? "session"
            switch change.op {
            case .delete: return "Drop \(weekday)'s \(what)"
            case .create: return "Add \(weekday)'s \(change.after.map(kind) ?? what)"
            case .update:
                if let before = change.before, let after = change.after {
                    if before._type != after._type { return "Swap \(weekday)'s \(kind(before)) for an \(kind(after))" }
                    return grows(before, after) ? "Add to \(weekday)'s \(what)" : "Ease \(weekday)'s \(what)"
                }
                return "Change \(weekday)'s \(what)"
            }
        }
        let updates = counted.filter { $0.op == .update }
        if updates.count == counted.count, !updates.isEmpty {
            if updates.allSatisfy({ eases($0) }) { return "Ease the week ahead" }
            if updates.allSatisfy({ grows($0.before, $0.after) }) { return "Add a little to the week ahead" }
        }
        if counted.allSatisfy({ $0.op == .delete }) { return "Drop \(counted.count) sessions" }
        return "Adjust the weeks ahead"
    }

    private static func eases(_ change: Components.Schemas.ProposalChange) -> Bool {
        guard let before = change.before, let after = change.after else { return false }
        return !grows(before, after)
    }

    private static func grows(_ before: Content?, _ after: Content?) -> Bool {
        guard let before, let after else { return false }
        let (a, b) = (PlanPreview.metres(of: before), PlanPreview.metres(of: after))
        if a > 0 || b > 0 { return b > a }
        return SessionSummary.estimatedSeconds(after) > SessionSummary.estimatedSeconds(before)
    }

    // MARK: Dates

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Sat, Oct 31" from `YYYY-MM-DD`.
    static func dayLabel(_ date: String) -> String {
        guard let parts = monthDay(date) else { return date }
        return "\(PlanPreview.weekdayName(PlanPreview.dayNumber(date))), \(parts.month) \(parts.day)"
    }

    static func monthDay(_ date: String) -> (month: String, day: Int)? {
        let numbers = date.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3, (1...12).contains(numbers[1]) else { return nil }
        return (months[numbers[1] - 1], numbers[2])
    }

    private static func note(_ changes: Components.Schemas.ProposalPlanChanges) -> String? {
        var parts: [String] = []
        if let goal = changes.goal {
            var text = PlanPreview.goalName(goal)
            if let date = goal.date, let day = monthDay(date) { text += " on \(day.month) \(day.day)" }
            parts.append(text)
        }
        if let count = changes.weekCount { parts.append("\(count) weeks in total") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
