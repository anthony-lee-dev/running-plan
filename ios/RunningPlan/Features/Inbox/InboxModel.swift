import APIClient
import Foundation

/// Local calendar dates as `YYYY-MM-DD` strings. An activity belongs to the day it started on in the user's own time
/// zone (design §8.3), so travel does not move it. Compare these strings, never `Date`s.
enum LocalDay {
    static func string(from date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// `2026-10-26` as `Mon, Oct 26`.
    static func heading(_ date: String) -> String {
        "\(PlanPreview.weekdayName(PlanPreview.dayNumber(date))), \(PlanPreview.shortDate(date))"
    }

    /// Noon on a local date in `zone`: a start time for an activity typed in by hand, safe from midnight edges.
    static func noon(of date: String, in zone: TimeZone) -> Date {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: parts.count == 3 ? parts[0] : 1970, month: parts.count == 3 ? parts[1] : 1, day: parts.count == 3 ? parts[2] : 1, hour: 12)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}

/// Which planned sessions an imported workout can be matched to. Mirrors `fits` in `api/src/domain/suggestions.ts`; change both together.
enum InboxMatching {
    typealias Session = Components.Schemas.Session
    typealias Activity = Components.Schemas.Activity

    static func fits(_ workout: Components.Schemas.WorkoutType, _ session: Components.Schemas.SessionType) -> Bool {
        switch workout {
        case .running: [.easy, .long, .intervals, .tempo].contains(session)
        case .strength: session == .strength
        default: session == .custom
        }
    }

    /// Live, not rest, not already done.
    static func isOpen(_ session: Session) -> Bool {
        session.value1.deletedAt == nil && session.value2._type != .rest && session.value2.status != .done
    }

    /// Same local date, a type that fits, still open and not claimed by another workout.
    static func sameDay(for activity: Activity, sessions: [Session], excluding claimed: Set<String> = []) -> [Session] {
        sessions
            .filter { isOpen($0) && $0.value2.date == activity.value1.localDate && fits(activity.value1.workoutType, $0.value2._type) && !claimed.contains($0.value1.id) }
            .sorted { $0.value1.id < $1.value1.id }
    }
}

/// DK-Inbox: what each waiting workout shows and offers. Pure: built from the activities, the plan's sessions, the
/// server's suggestions (by activity id) and today's local date.
struct InboxModel {
    typealias Session = Components.Schemas.Session
    typealias Activity = Components.Schemas.Activity

    enum Kind: Equatable {
        /// A session the workout probably belongs to, with its name for the card.
        case likelyMatch(sessionId: String, label: String)
        /// A run on a day with nothing to match it to.
        case extraRun
        /// Strength or other workouts with nothing to match.
        case otherWorkout
    }

    struct Card: Equatable, Identifiable {
        let id: String
        let heading: String
        let headline: String
        let detail: String
        let kind: Kind
    }

    struct Choice: Equatable, Identifiable {
        let id: String
        let title: String
        /// `Mon, Oct 26`, with "missed" when the day is over and nothing was done.
        let when: String
    }

    let cards: [Card]
    /// Past sessions still planned with nothing matched: shown as a note, and offered first in the picker.
    let missedCount: Int
    private let activities: [Activity]
    private let sessions: [Session]
    private let today: String

    init(activities: [Activity], sessions: [Session], suggestions: [String: String] = [:], today: String) {
        let live = sessions.filter { $0.value1.deletedAt == nil }
        self.activities = activities
        self.sessions = live
        self.today = today
        let byId = Dictionary(live.map { ($0.value1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func suggested(_ activity: Activity) -> String? {
            let id = activity.value2.match?.sessionId ?? suggestions[activity.value2.id]
            return id.flatMap { byId[$0] }.flatMap { InboxMatching.isOpen($0) ? $0.value1.id : nil }
        }
        // Sessions already offered to one workout are not offered to another (two runs on one day).
        var claimed = Set(activities.compactMap(suggested))
        cards = activities.map { activity in
            let fields = activity.value1
            var sessionId = suggested(activity)
            if sessionId == nil, let first = InboxMatching.sameDay(for: activity, sessions: live, excluding: claimed).first {
                sessionId = first.value1.id
                claimed.insert(first.value1.id)
            }
            let kind: Kind
            if let sessionId, let session = byId[sessionId] {
                kind = .likelyMatch(sessionId: sessionId, label: Self.label(session))
            } else {
                kind = fields.workoutType == .running ? .extraRun : .otherWorkout
            }
            return Card(
                id: activity.value2.id,
                heading: "\(LocalDay.heading(fields.localDate)) · \(fields.sourceApp ?? "Apple Health")",
                headline: Self.headline(fields),
                detail: Self.detail(fields),
                kind: kind
            )
        }
        missedCount = live.filter { InboxMatching.isOpen($0) && $0.value2.status != .skipped && $0.value2.date < today }.count
    }

    var subtitle: String {
        cards.count == 1 ? "1 workout waiting. Confirm where it belongs so your plan stays accurate."
            : "\(cards.count) workouts waiting. Confirm where they belong so your plan stays accurate."
    }

    /// Why the picker is empty: only when the plan has no open session of a fitting type at all (any date), else nil.
    func emptyChoicesNote(for activityId: String) -> String? {
        choices(for: activityId).isEmpty ? "Your plan has no open session of this type left to match it to." : nil
    }

    /// Every open session of a fitting type in the plan, nearest the workout's day first (a plan rebuilt after the run
    /// can start days or weeks away, issue #98). Past ones are missed sessions.
    func choices(for activityId: String) -> [Choice] {
        guard let activity = activities.first(where: { $0.value2.id == activityId }) else { return [] }
        let day = PlanPreview.dayNumber(activity.value1.localDate)
        let todayNumber = PlanPreview.dayNumber(today)
        return sessions
            .filter { InboxMatching.isOpen($0) && InboxMatching.fits(activity.value1.workoutType, $0.value2._type) }
            .sorted {
                let a = abs(PlanPreview.dayNumber($0.value2.date) - day), b = abs(PlanPreview.dayNumber($1.value2.date) - day)
                return a != b ? a < b : $0.value2.date < $1.value2.date
            }
            .map { session in
                let missed = PlanPreview.dayNumber(session.value2.date) < todayNumber && session.value2.status != .skipped
                return Choice(id: session.value1.id, title: Self.label(session), when: LocalDay.heading(session.value2.date) + (missed ? " · missed" : ""))
            }
    }

    // MARK: Text

    static func label(_ session: Session) -> String {
        let name = session.value2.title ?? SessionSummary.effort(session.value2)
        let metres = PlanPreview.metres(of: session.value2)
        return metres > 0 ? "\(name) · \(PlanPreview.kilometres(metres / 1000)) km" : name
    }

    static func duration(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func headline(_ a: Components.Schemas.ActivityFields) -> String {
        let time = duration(a.durationSec)
        guard let metres = a.distanceM, metres > 0 else { return time }
        return "\(PlanPreview.kilometres(Double(metres) / 1000)) km · \(time)"
    }

    static func detail(_ a: Components.Schemas.ActivityFields) -> String {
        var parts: [String] = []
        if a.workoutType == .running, let metres = a.distanceM, metres > 0 {
            parts.append("\(PaceFormat.minutesSeconds(Int((Double(a.durationSec) / (Double(metres) / 1000)).rounded())))/km average")
        } else if a.workoutType != .running {
            parts.append(a.workoutType.rawValue.capitalized)
        }
        if let hr = a.avgHeartRate { parts.append("\(hr) bpm") }
        return parts.joined(separator: " · ")
    }
}
