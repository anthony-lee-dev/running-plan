import APIClient
import Foundation

/// What Goal and settings shows about the plan's goal, and the pure rules behind its two goal actions: editing the
/// goal's date and target time (`updatePlan`) and re-running the interview (`generateProposals` with `interview`).
enum GoalModel {
    typealias Goal = Components.Schemas.Goal

    /// The interview's limit (`InterviewFlow.maxUnavailableDays`, `unavailableDays` maxItems 4 in the spec).
    static let maxUnavailableDays = 4

    /// "10K in 55:00" and "Race day Sunday, Dec 13", or "No race date" when the goal has none.
    struct Summary: Equatable {
        let title: String
        let detail: String
    }

    static func summary(_ goal: Goal) -> Summary {
        let detail: String
        if goal._type != .none, let date = goal.date {
            detail = "Race day \(NextModel.weekday(date)), \(PlanPreview.shortDate(date))"
        } else {
            detail = "No race date"
        }
        return Summary(title: WholeModel.title(goal), detail: detail)
    }

    /// The review row's value: "Weekly plus urgent · Last day of the week", or "Off".
    static func reviewLine(_ setting: ReviewSetting) -> String {
        let title = ReviewFrequencyCopy.title(setting.frequency)
        return setting.frequency == .off ? title : "\(title) · \(ReviewFrequencyCopy.title(day: setting.day))"
    }

    // MARK: Editing the goal

    /// The plan's goal with a new date and target time (in minutes). The type and any custom label stay: changing the
    /// distance is what re-running the interview is for. A time is kept inside what the API accepts (60 s to 24 h).
    static func edited(_ goal: Goal, date: String?, targetMinutes: Int?) -> Goal {
        let seconds = targetMinutes.map { min(max($0 * 60, 60), 86_400) }
        return Goal(_type: goal._type, label: goal.label, date: date, targetTimeSec: seconds)
    }

    // MARK: Re-running the interview

    /// The interview's answers as far as the plan and profile show them, so the re-run starts from what the user has.
    /// Nil for a plan with a custom goal or none, which starts the interview fresh. The interview accepts less than the
    /// plan and profile can hold (a goal time of 10 minutes to 6 hours, at most 4 days off, a past date is useless), so
    /// anything outside is left out and the question is asked again.
    static func answers(goal: Goal, profile: Components.Schemas.Profile?, today: String) -> InterviewAnswers? {
        guard let distance = GoalDistance(rawValue: goal._type.rawValue) else { return nil }
        var answers = InterviewAnswers()
        answers.goal.distance = distance
        if let date = goal.date, date >= today { answers.goal.date = date }
        if let seconds = goal.targetTimeSec, (600...21_600).contains(seconds) { answers.goal.targetTimeSec = seconds }
        guard let profile else { return answers }

        answers.targetDisplay = TargetDisplay(rawValue: profile.targetDisplay.rawValue)
        if let maxBpm = profile.heartRate.maxBpm { answers.heartRate = .init(maxBpm: min(max(maxBpm, 100), 230)) }
        var unavailable: [Weekday] = []
        for day in profile.scheduling.unavailableDays ?? [] {
            if let mapped = Weekday(rawValue: day.rawValue), !unavailable.contains(mapped) { unavailable.append(mapped) }
        }
        if !unavailable.isEmpty, unavailable.count <= Self.maxUnavailableDays { answers.unavailableDays = unavailable }
        if let day = profile.scheduling.longRunDay.flatMap({ Weekday(rawValue: $0.rawValue) }), !(answers.unavailableDays ?? []).contains(day) {
            answers.longRunDay = day
        }
        return answers
    }

    /// The same answers as the API's type, by way of JSON (they share the spec's shape; `APIPlanGenerator` does this too).
    static func apiAnswers(_ answers: InterviewAnswers) throws -> Components.Schemas.InterviewAnswers {
        try JSONDecoder().decode(Components.Schemas.InterviewAnswers.self, from: JSONEncoder().encode(answers))
    }
}
