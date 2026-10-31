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

    /// The goal card. "On track" waits for the progress endpoint (backlog 2.15).
    struct Goal: Equatable {
        let title: String
        let subtitle: String
        let progress: Double
        let weekLabel: String
        let doneLabel: String
    }

    struct Bar: Equatable {
        let week: Int
        let kilometres: Double
        let phase: PlanPreview.Phase?
        let isCurrent: Bool
        /// Weeks still to come are drawn faded.
        let isAhead: Bool
    }

    let rows: [Row]
    let goal: Goal
    let bars: [Bar]
    let chartSpoken: String

    init(schedule: PlanSchedule) {
        let planGoal = schedule.plan.value1.value2.goal
        // Only a plan towards a dated race has a race week.
        let hasRace = planGoal._type != .none && planGoal.date != nil
        let current: Int? = if case .week(let index) = schedule.position { index } else { nil }
        let metres = (0..<schedule.weekCount).map { schedule.plannedMetres(week: $0) }
        let km = metres.map { Int(($0 / 1000).rounded()) }
        let weeksDone: Int
        let weekLabel: String
        switch schedule.position {
        case .notStarted(let start):
            weeksDone = 0
            weekLabel = "Starts \(PlanPreview.shortDate(start))"
        case .week(let index):
            weeksDone = index
            weekLabel = "Week \(index + 1) of \(schedule.weekCount)"
        case .finished:
            weeksDone = schedule.weekCount
            weekLabel = "Plan finished"
        }
        goal = Goal(
            title: Self.title(planGoal),
            subtitle: Self.subtitle(planGoal, schedule: schedule),
            // Whole weeks done; the board's bar also counts part of this week, which needs distance run (4.7).
            progress: schedule.weekCount > 0 ? Double(weeksDone) / Double(schedule.weekCount) : 0,
            weekLabel: weekLabel,
            doneLabel: weeksDone == 1 ? "1 week done" : "\(weeksDone) weeks done"
        )
        bars = (0..<schedule.weekCount).map { week in
            Bar(
                week: week,
                kilometres: (metres[week] / 100).rounded() / 10,
                phase: schedule.phase(ofWeek: week),
                isCurrent: week == current,
                isAhead: week >= weeksDone && week != current
            )
        }
        var spoken = ["Weekly distance for the \(schedule.weekCount)-week plan."]
        var progressParts: [String] = []
        if weeksDone == 1 { progressParts.append("Week 1 done") } else if weeksDone > 1 { progressParts.append("Weeks 1 to \(weeksDone) done") }
        if let current { progressParts.append("week \(current + 1) this week") }
        if let longest = km.max() { progressParts.append("longest week \(longest) km") }
        if !progressParts.isEmpty { spoken.append(progressParts.joined(separator: ", ") + ".") }
        chartSpoken = spoken.joined(separator: " ")
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

    /// "10K in 55:00", "Half marathon in 1:45:00", or the goal's name alone.
    private static func title(_ goal: Components.Schemas.Goal) -> String {
        let name = PlanPreview.goalName(goal)
        guard goal._type != .none, let seconds = goal.targetTimeSec else { return name }
        let time = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(name) in \(time)"
    }

    /// "Race day Sunday, Dec 13 · 46 days to go", or when the plan ends if there is no race date.
    private static func subtitle(_ goal: Components.Schemas.Goal, schedule: PlanSchedule) -> String {
        guard goal._type != .none, let date = goal.date else {
            let end = schedule.weekRange(max(schedule.weekCount - 1, 0)).last
            return "Ends \(NextModel.weekday(end)), \(PlanPreview.shortDate(end))"
        }
        let days = PlanPreview.dayNumber(date) - PlanPreview.dayNumber(schedule.today)
        if days < 0 { return "Race was \(NextModel.weekday(date)), \(PlanPreview.shortDate(date))" }
        let when: String
        switch days {
        case 0: when = "today"
        case 1: when = "1 day to go"
        default: when = "\(days) days to go"
        }
        return "Race day \(NextModel.weekday(date)), \(PlanPreview.shortDate(date)) · \(when)"
    }
}
