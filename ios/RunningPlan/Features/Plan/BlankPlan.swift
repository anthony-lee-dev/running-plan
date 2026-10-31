import APIClient
import Foundation

/// "I'd rather build my own plan": an empty plan the user fills from the Plan tab. Blank plans have no engine and are
/// not adaptive (design §5), so the engine never proposes changes to them.
enum BlankPlan {
    static let defaultWeeks = 8

    /// The Monday of `today`'s week, so the plan's weeks line up with the calendar.
    static func startDate(today: String) -> String {
        let day = PlanPreview.dayNumber(today)
        let fromMonday = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].firstIndex(of: PlanPreview.weekdayName(day)) ?? 0
        return PlanSchedule.date(dayNumber: day - fromMonday)
    }

    /// Weeks from this Monday to the goal date, or eight without a (future) date; 1 to 52.
    static func suggestedWeeks(goal: InterviewAnswers.Goal?, today: String) -> Int {
        guard let date = goal?.date, date > today else { return defaultWeeks }
        let days = PlanPreview.dayNumber(date) - PlanPreview.dayNumber(startDate(today: today)) + 1
        return min(max((days + 6) / 7, 1), 52)
    }

    /// `goal` is nil when the interview never got as far as choosing one.
    static func body(goal: InterviewAnswers.Goal?, today: String, weeks: Int, id: String) -> Components.Schemas.PlanCreate {
        let planGoal: Components.Schemas.Goal
        if let goal {
            let type: Components.Schemas.Goal._typePayload = switch goal.distance {
            case .fiveK: ._5k
            case .tenK: ._10k
            case .halfMarathon: .half_marathon
            }
            planGoal = .init(_type: type, date: goal.date.flatMap { $0 > today ? $0 : nil }, targetTimeSec: goal.targetTimeSec)
        } else {
            planGoal = .init(_type: .none)
        }
        return .init(
            value1: .init(goal: planGoal, startDate: startDate(today: today), weekCount: min(max(weeks, 1), 52), source: .blank, adaptive: false, weeks: []),
            value2: .init(id: id, sessions: [])
        )
    }
}
