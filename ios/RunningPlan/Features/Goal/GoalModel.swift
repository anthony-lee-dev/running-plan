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

    /// The seconds to send for a target time the user set in whole minutes. Opening the editor never changes the time:
    /// while the minutes are as they were shown, the original seconds (55:30, say) go back unchanged.
    static func targetSeconds(original: Int?, minutes: Int) -> Int {
        if let original, original / 60 == minutes { return original }
        return minutes * 60
    }

    /// The plan's goal with a new date and target time. The type and any custom label stay: changing the distance is what
    /// re-running the interview is for. A time is kept inside what the API accepts (60 s to 24 h).
    static func edited(_ goal: Goal, date: String?, targetSeconds: Int?) -> Goal {
        Goal(_type: goal._type, label: goal.label, date: date, targetTimeSec: targetSeconds.map { min(max($0, 60), 86_400) })
    }

    // MARK: Re-running the interview

    /// The interview's answers as far as the plan and profile show them, so the re-run starts from what the user has:
    /// the answers the plan was made from (`engine.interview`), then the plan's goal as it is now, then the profile's
    /// target display, heart rate max, days off and long-run day. Nil for a plan with a custom goal or none and no stored
    /// answers, which starts the interview fresh. The interview accepts less than the plan and profile can hold (a goal
    /// time of 10 minutes to 6 hours, at most 4 days off, a past date is useless), so anything outside is left out and
    /// the question is asked again.
    static func answers(goal: Goal, interview: Components.Schemas.InterviewAnswers?, profile: Components.Schemas.Profile?, today: String) -> InterviewAnswers? {
        var answers = interview.flatMap { try? JSONDecoder().decode(InterviewAnswers.self, from: JSONEncoder().encode($0)) } ?? InterviewAnswers()
        if let distance = GoalDistance(rawValue: goal._type.rawValue) {
            answers.goal.distance = distance
        } else if interview == nil {
            return nil
        }
        // The goal as the plan has it now (it may have been edited since the interview).
        answers.goal.date = goal.date.flatMap { $0 >= today ? $0 : nil }
        answers.goal.targetTimeSec = goal.targetTimeSec.flatMap { (600...21_600).contains($0) ? $0 : nil }

        if let profile {
            answers.targetDisplay = TargetDisplay(rawValue: profile.targetDisplay.rawValue)
            if let maxBpm = profile.heartRate.maxBpm { answers.heartRate = .init(maxBpm: min(max(maxBpm, 100), 230)) }
            var unavailable: [Weekday] = []
            for day in profile.scheduling.unavailableDays ?? [] {
                if let mapped = Weekday(rawValue: day.rawValue), !unavailable.contains(mapped) { unavailable.append(mapped) }
            }
            if !unavailable.isEmpty { answers.unavailableDays = unavailable.count <= Self.maxUnavailableDays ? unavailable : nil }
            if let day = profile.scheduling.longRunDay.flatMap({ Weekday(rawValue: $0.rawValue) }) { answers.longRunDay = day }
        }
        if let day = answers.longRunDay, (answers.unavailableDays ?? []).contains(day) { answers.longRunDay = nil }
        return answers
    }

    /// The same answers as the API's type, by way of JSON (they share the spec's shape; `APIPlanGenerator` does this too).
    static func apiAnswers(_ answers: InterviewAnswers) throws -> Components.Schemas.InterviewAnswers {
        try JSONDecoder().decode(Components.Schemas.InterviewAnswers.self, from: JSONEncoder().encode(answers))
    }
}
