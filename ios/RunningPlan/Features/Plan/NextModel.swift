import APIClient
import Foundation

/// Everything DK-Next shows, worked out from the plan and today's date.
struct NextModel: Equatable {
    struct Focus: Equatable {
        /// The session on the card, for Open workout, Make it easier and Move or skip.
        let sessionId: String
        /// Rest and finished sessions have nothing to make easier.
        let canAdjust: Bool
        let label: String
        let title: String
        let effort: String
        let detail: String
        let shape: [SessionSummary.Segment]
        let why: String
    }

    enum DayState: Equatable {
        case done, skipped, rest
        /// Still to do; the day of the month.
        case planned(String)
    }

    struct Day: Equatable {
        let letter: String
        let weekday: String
        let state: DayState
        let isToday: Bool
    }

    /// Why there is no card: the plan has ended, or nothing is left to do in it (no sessions, or past the last one).
    enum NothingToDo: Equatable {
        case finished, noMoreSessions
    }

    let eyebrow: String
    /// Today's session, or the next one when today has none. Nil once the plan is finished.
    let focus: Focus?
    /// This week, day by day; empty before the start and after the end.
    let week: [Day]
    let weekHeader: String?
    let weekProgress: Double
    /// The session after the one on the card, when the card is today's.
    let nextUp: String?
    /// Set when there is no card.
    let nothingToDo: NothingToDo?
    /// The week strip as one VoiceOver sentence.
    var weekSpoken: String {
        "This week: " + week.map { day in
            let state: String
            switch day.state {
            case .done: state = "done"
            case .skipped: state = "skipped"
            case .rest: state = "rest"
            case .planned: state = day.isToday ? "today" : "planned"
            }
            return "\(day.weekday) \(state)"
        }.joined(separator: ", ")
    }

    init(schedule: PlanSchedule) {
        let today = schedule.today
        let day = "\(Self.weekday(today)), \(PlanPreview.shortDate(today))"
        // Only what is still to do today; a session done or skipped gives way to the next one.
        let todays = schedule.todaySessions.filter { $0.value2.status == .planned }
        // A run before strength when a day has both.
        let todayMain = todays.first { $0.value2._type != .strength && $0.value2._type != .custom } ?? todays.first

        switch schedule.position {
        case .notStarted(let start):
            eyebrow = "\(day) · Starts \(Self.weekday(start)), \(PlanPreview.shortDate(start))"
            focus = schedule.nextSession.map { Self.focus($0, label: "FIRST SESSION · \(Self.weekday($0.value2.date).uppercased()), \(PlanPreview.shortDate($0.value2.date).uppercased())") }
            week = []
            weekHeader = nil
            weekProgress = 0
            nextUp = nil
        case .finished:
            eyebrow = "\(day) · Plan finished"
            focus = nil
            week = []
            weekHeader = nil
            weekProgress = 0
            nextUp = nil
        case .week(let index):
            let phase = schedule.phase(ofWeek: index).map { " · \($0.title)" } ?? ""
            eyebrow = "\(day) · Week \(index + 1) of \(schedule.weekCount)\(phase)"
            if let todayMain {
                focus = Self.focus(todayMain, label: "TODAY")
                nextUp = schedule.nextSession.map { "Next up: \($0.value2.title ?? SessionSummary.effort($0.value2)), \(Self.weekday($0.value2.date)) · \(Self.size($0.value2))" }
            } else {
                focus = schedule.nextSession.map { Self.focus($0, label: "NEXT UP · \(Self.weekday($0.value2.date).uppercased()), \(PlanPreview.shortDate($0.value2.date).uppercased())") }
                nextUp = nil
            }
            let sessions = schedule.sessions(inWeek: index)
            week = schedule.days(ofWeek: index).map { date in
                let onDay = sessions.filter { $0.value2.date == date && $0.value2._type != .rest }.map(\.value2)
                let number = String(Int(date.suffix(2)) ?? 0)
                let state: DayState
                if onDay.isEmpty {
                    state = .rest
                } else if onDay.allSatisfy({ $0.status == .done }) {
                    state = .done
                } else if onDay.allSatisfy({ $0.status == .skipped }) {
                    state = .skipped
                } else {
                    state = .planned(number)
                }
                let weekday = Self.weekday(date)
                return Day(letter: String(weekday.prefix(1)), weekday: weekday, state: state, isToday: date == today)
            }
            let count = schedule.sessionCount(week: index)
            let done = schedule.doneCount(week: index)
            // Weekly totals are whole kilometres, as on the boards ("25 km" for 24.9).
            weekHeader = "\(Int((schedule.plannedMetres(week: index) / 1000).rounded())) km planned · \(done) of \(count) sessions"
            weekProgress = count > 0 ? Double(done) / Double(count) : 0
        }
        nothingToDo = Self.nothing(focus, schedule.position)
    }

    private static func nothing(_ focus: Focus?, _ position: PlanSchedule.Position) -> NothingToDo? {
        guard focus == nil else { return nil }
        return position == .finished ? .finished : .noMoreSessions
    }

    private static func focus(_ session: Components.Schemas.Session, label: String) -> Focus {
        let s = session.value2
        return Focus(
            sessionId: session.value1.id,
            canAdjust: s._type != .rest && (s.status ?? .planned) == .planned,
            label: label,
            title: s.title ?? SessionSummary.effort(s),
            effort: SessionSummary.effort(s),
            detail: SessionSummary.detail(s),
            shape: SessionSummary.shape(s),
            why: SessionSummary.why(s)
        )
    }

    /// "5 km", or "20 min" for a session not measured in distance.
    private static func size(_ s: Components.Schemas.SessionContent) -> String {
        let metres = PlanPreview.metres(of: s)
        if metres > 0 { return "\(PlanPreview.kilometres(metres / 1000)) km" }
        return SessionSummary.detail(s).components(separatedBy: " · ").first ?? ""
    }

    static func weekday(_ date: String) -> String {
        let short = PlanPreview.weekdayName(PlanPreview.dayNumber(date))
        return ["Mon": "Monday", "Tue": "Tuesday", "Wed": "Wednesday", "Thu": "Thursday", "Fri": "Friday", "Sat": "Saturday", "Sun": "Sunday"][short] ?? short
    }
}
