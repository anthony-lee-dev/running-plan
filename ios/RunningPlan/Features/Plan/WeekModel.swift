import APIClient
import Foundation

/// Everything DK-Week shows for one week of the plan.
struct WeekModel: Equatable {
    enum Badge: Equatable {
        case easy, long, yours
    }

    enum Trailing: Equatable {
        case done, skipped, today
        case badge(Badge)
        case none
    }

    struct Item: Equatable {
        let title: String
        let detail: String
        let trailing: Trailing
        /// Today's card keeps its border whatever its status.
        let isToday: Bool
        /// Only today's card shows the workout shape.
        let shape: [SessionSummary.Segment]
    }

    struct Day: Equatable {
        /// "MON", or "TODAY".
        let weekday: String
        let number: String
        let isToday: Bool
        /// No session to do (none, or only rest sessions).
        let isRest: Bool
        let items: [Item]
        /// The day as one VoiceOver sentence.
        let spoken: String
    }

    let week: Int
    let title: String
    let range: String
    let canGoBack: Bool
    let canGoForward: Bool
    let planned: String
    let summary: String
    let progress: Double
    let days: [Day]

    /// This week while the plan runs; week 1 before it starts; the last week after it ends.
    static func initialWeek(_ schedule: PlanSchedule) -> Int {
        switch schedule.position {
        case .week(let index): index
        case .notStarted: 0
        case .finished: max(schedule.weekCount - 1, 0)
        }
    }

    init(schedule: PlanSchedule, week: Int) {
        self.week = week
        let phase = schedule.phase(ofWeek: week).map { " · \($0.title)" } ?? ""
        title = "Week \(week + 1)\(phase)"
        let (first, last) = schedule.weekRange(week)
        range = "\(PlanPreview.shortDate(first)) – \(PlanPreview.shortDate(last))"
        canGoBack = week > 0
        canGoForward = week < schedule.weekCount - 1

        let sessions = schedule.sessions(inWeek: week)
        // Weekly totals are whole kilometres, as on the boards.
        planned = "\(Int((schedule.plannedMetres(week: week) / 1000).rounded())) km planned"
        let count = schedule.sessionCount(week: week)
        let done = schedule.doneCount(week: week)
        // The board's "5.1 km done · plus 45 min cross-training" needs distance run (progress endpoint, 2.15).
        summary = "\(done) of \(count) sessions done"
        progress = count > 0 ? Double(done) / Double(count) : 0

        days = schedule.days(ofWeek: week).map { date in
            let isToday = date == schedule.today
            let fullWeekday = NextModel.weekday(date)
            let number = String(Int(date.suffix(2)) ?? 0)
            let onDay = sessions.filter { $0.value2.date == date && $0.value2._type != .rest }.map(\.value2)
            let items = onDay.map { s in
                let trailing: Trailing
                if s.status == .done {
                    trailing = .done
                } else if s.status == .skipped {
                    trailing = .skipped
                } else if isToday {
                    trailing = .today
                } else if s.owner == .user {
                    trailing = .badge(.yours)
                } else if s._type == .easy {
                    trailing = .badge(.easy)
                } else if s._type == .long {
                    trailing = .badge(.long)
                } else {
                    trailing = .none
                }
                return Item(
                    title: s.title ?? SessionSummary.effort(s),
                    detail: SessionSummary.detail(s, withTime: isToday),
                    trailing: trailing,
                    isToday: isToday,
                    shape: isToday && trailing == .today ? SessionSummary.shape(s) : []
                )
            }
            let when = (isToday ? "Today, " : "") + "\(fullWeekday) \(number)"
            let spoken = items.isEmpty
                ? "\(when): rest day"
                : "\(when): " + items.map { item in
                    let state: String
                    switch item.trailing {
                    case .done: state = ", done"
                    case .skipped: state = ", skipped"
                    default: state = ""
                    }
                    return "\(item.title), \(PaceFormat.spoken(item.detail))\(state)"
                }.joined(separator: "; ")
            return Day(
                weekday: isToday ? "TODAY" : String(fullWeekday.prefix(3)).uppercased(),
                number: number,
                isToday: isToday,
                isRest: items.isEmpty,
                items: items,
                spoken: spoken
            )
        }
    }
}
