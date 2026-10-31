import APIClient
import Foundation

/// Where a saved plan stands on a given local date: which week it is, what is on today, what comes next, and each
/// week's sessions. Pure: `today` is passed in (`YYYY-MM-DD`), and weeks are counted on calendar days, never on `Date`.
struct PlanSchedule {
    typealias Session = Components.Schemas.Session

    enum Position: Equatable {
        case notStarted(startsOn: String)
        /// The week index, 0 for week 1.
        case week(Int)
        case finished
    }

    let plan: Components.Schemas.PlanDetail
    let today: String
    let startDate: String
    let weekCount: Int
    /// Live sessions in date order.
    let sessions: [Session]
    private let start: Int
    private let todayNumber: Int

    init(plan: Components.Schemas.PlanDetail, today: String) {
        self.plan = plan
        self.today = today
        startDate = plan.value1.value2.startDate
        weekCount = plan.value1.value2.weekCount
        sessions = plan.value2.sessions.filter { $0.value1.deletedAt == nil }.sorted { $0.value2.date < $1.value2.date }
        start = PlanPreview.dayNumber(startDate)
        todayNumber = PlanPreview.dayNumber(today)
    }

    var position: Position {
        if todayNumber < start { return .notStarted(startsOn: startDate) }
        let week = (todayNumber - start) / 7
        return week < weekCount ? .week(week) : .finished
    }

    func week(of date: String) -> Int {
        let offset = PlanPreview.dayNumber(date) - start
        return offset >= 0 ? offset / 7 : -1
    }

    func phase(ofWeek index: Int) -> PlanPreview.Phase? {
        plan.value1.value2.weeks.first { $0.index == index }?.phase.flatMap { PlanPreview.Phase(rawValue: $0.rawValue) }
    }

    /// Every session in the week, rest included (the Week screen shows rest days).
    func sessions(inWeek index: Int) -> [Session] {
        sessions.filter { week(of: $0.value2.date) == index }
    }

    /// The week's seven dates, counted from the plan's start date (a Monday for rule-generated plans).
    func days(ofWeek index: Int) -> [String] {
        (0..<7).map { Self.date(dayNumber: start + index * 7 + $0) }
    }

    func weekRange(_ index: Int) -> (first: String, last: String) {
        (Self.date(dayNumber: start + index * 7), Self.date(dayNumber: start + index * 7 + 6))
    }

    var todaySessions: [Session] {
        sessions.filter { $0.value2.date == today && $0.value2._type != .rest }
    }

    /// The first session after today that is still to do (not rest, not skipped in advance).
    var nextSession: Session? {
        sessions.first { $0.value2.date > today && $0.value2._type != .rest && $0.value2.status != .skipped }
    }

    /// Planned running distance; strength and cross-training count for nothing.
    func plannedMetres(week index: Int) -> Double {
        sessions(inWeek: index).reduce(0) { $0 + PlanPreview.metres(of: $1.value2) }
    }

    /// Sessions to do in the week. Rest is not one, as in the server's progress (`api/src/domain/insights.ts`).
    func sessionCount(week index: Int) -> Int {
        sessions(inWeek: index).filter { $0.value2._type != .rest }.count
    }

    /// Sessions marked done. Distance actually run comes from the progress endpoint (backlog 2.15), not from here.
    func doneCount(week index: Int) -> Int {
        sessions(inWeek: index).filter { $0.value2._type != .rest && $0.value2.status == .done }.count
    }

    /// `YYYY-MM-DD` for a day number from `PlanPreview.dayNumber`.
    static func date(dayNumber: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(dayNumber) * 86_400))
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
