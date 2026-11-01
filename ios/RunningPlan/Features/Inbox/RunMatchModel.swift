import APIClient
import Foundation

/// Runs seen from a session (its matched run, the runs it could take) and from the run's side (every imported run and
/// where it stands). Pure; issue #105. The matching rules live in `InboxMatching`.
enum RunMatchModel {
    typealias Session = Components.Schemas.Session
    typealias Activity = Components.Schemas.Activity

    /// One imported run as the session page and the all-runs list show it.
    struct RunRow: Equatable, Identifiable {
        let id: String
        let heading: String
        let headline: String
        let detail: String
    }

    static func row(for activity: Activity) -> RunRow {
        let fields = activity.value1
        return RunRow(
            id: activity.value2.id,
            heading: "\(LocalDay.heading(fields.localDate)) · \(fields.sourceApp ?? "Apple Health")",
            headline: InboxModel.headline(fields),
            detail: InboxModel.detail(fields)
        )
    }

    /// The run confirmed to this session, if any (needs the full run list: matched runs are not in the inbox).
    static func matchedRun(for sessionId: String, in activities: [Activity]) -> Activity? {
        activities.first { $0.value2.disposition == .matched && $0.value2.match?.sessionId == sessionId }
    }

    /// "Match a run" is offered for a live session that is not rest and is today or earlier. A future session has no run yet.
    static func canMatch(_ session: Session, today: String) -> Bool {
        session.value1.deletedAt == nil && session.value2._type != .rest && session.value2.date <= today
    }

    /// Runs still in the inbox that fit this session's type, the one nearest its day first.
    static func candidates(for session: Session, in activities: [Activity]) -> [Activity] {
        let day = PlanPreview.dayNumber(session.value2.date)
        return activities
            .filter { $0.value2.disposition == .inbox && InboxMatching.fits($0.value1.workoutType, session.value2._type) }
            .sorted {
                let a = abs(PlanPreview.dayNumber($0.value1.localDate) - day), b = abs(PlanPreview.dayNumber($1.value1.localDate) - day)
                return a != b ? a < b : $0.value1.localDate > $1.value1.localDate
            }
    }
}

/// Every imported run, matched and not, for re-mapping from the run's side.
struct RunsModel {
    typealias Session = Components.Schemas.Session
    typealias Activity = Components.Schemas.Activity

    enum Status: Equatable {
        case matched(sessionId: String, label: String)
        case inbox
        case extra
        case ignored

        var text: String {
            switch self {
            case .matched(_, let label): "Matched to \(label)"
            case .inbox: "In your inbox"
            case .extra: "Extra run"
            case .ignored: "Ignored"
            }
        }
    }

    struct Row: Equatable, Identifiable {
        let run: RunMatchModel.RunRow
        let status: Status
        var id: String { run.id }
    }

    let rows: [Row]
    private let activities: [Activity]
    private let sessions: [Session]
    private let today: String

    init(activities: [Activity], sessions: [Session], today: String) {
        let live = sessions.filter { $0.value1.deletedAt == nil }
        let byId = Dictionary(live.map { ($0.value1.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.activities = activities
        self.sessions = live
        self.today = today
        rows = activities.map { activity in
            let status: Status
            switch activity.value2.disposition {
            case .matched:
                let session = activity.value2.match.flatMap { byId[$0.sessionId] }
                status = session.map { .matched(sessionId: $0.value1.id, label: "\(InboxModel.label($0)) on \(LocalDay.heading($0.value2.date))") } ?? .inbox
            case .inbox: status = .inbox
            case .extra: status = .extra
            case .ignored: status = .ignored
            }
            return Row(run: RunMatchModel.row(for: activity), status: status)
        }
    }

    /// Open sessions of a fitting type the run could move to, nearest its day first (same list as the inbox picker).
    func choices(for activityId: String) -> [InboxModel.Choice] {
        guard let activity = activities.first(where: { $0.value2.id == activityId }) else { return [] }
        return InboxModel(activities: [activity], sessions: sessions, today: today).choices(for: activityId)
    }
}
