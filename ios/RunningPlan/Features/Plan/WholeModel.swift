import APIClient
import Foundation

/// The week list of DK-Whole: one row per week, which opens that week. Distance actually run waits for the progress
/// endpoint (backlog 2.15); until then a week is ticked when every session in it is marked done.
struct WholeModel: Equatable {
    enum State: Equatable {
        case done, current, upcoming
    }

    struct Row: Equatable {
        let week: Int
        let label: String
        let detail: String
        let distance: String
        let state: State
        let spoken: String
    }

    let rows: [Row]

    init(schedule: PlanSchedule) {
        let goal = schedule.plan.value1.value2.goal
        // Only a plan towards a dated race has a race week.
        let hasRace = goal._type != .none && goal.date != nil
        let current: Int? = if case .week(let index) = schedule.position { index } else { nil }
        let km = (0..<schedule.weekCount).map { Int((schedule.plannedMetres(week: $0) / 1000).rounded()) }
        rows = (0..<schedule.weekCount).map { week in
            let phase = schedule.phase(ofWeek: week)
            let date = PlanPreview.shortDate(schedule.weekRange(week).first)
            var parts = [phase?.title].compactMap { $0 }
            if week == current {
                parts.append("This week")
            } else {
                parts.append(date)
                if hasRace, week == schedule.weekCount - 1 {
                    parts.append("race week")
                } else if week > 0, phase != .taper, km[week] < km[week - 1] {
                    parts.append("lighter week")
                }
            }
            let count = schedule.sessionCount(week: week)
            let state: State = week == current ? .current : (count > 0 && schedule.doneCount(week: week) == count ? .done : .upcoming)
            let spokenParts = ["Week \(week + 1)", phase?.title, week == current ? "this week" : date, "\(km[week]) kilometres", state == .done ? "done" : nil]
            return Row(
                week: week,
                label: "W\(week + 1)",
                detail: parts.joined(separator: " · "),
                distance: "\(km[week]) km",
                state: state,
                spoken: spokenParts.compactMap { $0 }.joined(separator: ", ")
            )
        }
    }
}
