import Foundation
import Observation

/// Appendix B of the system design, one question per screen.
enum InterviewQuestion: Int, CaseIterable, Identifiable, Sendable {
    case goalDistance, goalDateAndTime, recentResult, weeklyDistance, longestRun, history
    case runsAndDays, longRunDay, pain, strength, targetDisplay, heartRate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .goalDistance: "What are you training for?"
        case .goalDateAndTime: "Is there a date or a time in mind?"
        case .recentResult: "Have you run or raced lately?"
        case .weeklyDistance: "How far do you run in a week?"
        case .longestRun: "What was your longest recent run?"
        case .history: "How long have you been running?"
        case .runsAndDays: "How many days a week do you want to run?"
        case .longRunDay: "Which day suits your long run?"
        case .pain: "Any pain or injury right now?"
        case .strength: "Do you want strength sessions?"
        case .targetDisplay: "How should targets be shown?"
        case .heartRate: "Do you know your maximum heart rate?"
        }
    }

    var subtitle: String {
        switch self {
        case .goalDistance: "Pick a distance. We'll suggest a plan, and you can change any part of it later."
        case .goalDateAndTime: "Both are optional. Without a date we build a plan of the usual length."
        case .recentResult: "A run or race from the last 4 to 6 weeks helps us set your paces."
        case .weeklyDistance: "Your average over the last 4 weeks, in kilometres."
        case .longestRun: "The longest single run in the last 4 weeks, in kilometres."
        case .history: "Regular running, not the odd jog."
        case .runsAndDays: "Choose 3 to 5, and tick any days you can't run."
        case .longRunDay: "We'll put your longest run here."
        case .pain: "Yes or no only. Yes gives you a more cautious plan, and we suggest you check in with a qualified professional."
        case .strength: "Short sessions placed away from your hard runs."
        case .targetDisplay: "Paces are always minutes per kilometre."
        case .heartRate: "Only if you know it. We never estimate it for you."
        }
    }
}

/// State of the interview: where the user is and what they answered. Skipping a question clears its answer.
@MainActor
@Observable
final class InterviewFlow {
    private(set) var index = 0
    private(set) var answers = InterviewAnswers()
    private(set) var isFinished = false
    private(set) var wantsBlankPlan = false
    private var answered: Set<InterviewQuestion> = []
    /// Kept apart from `answers` so two inputs on one screen can be set in either order.
    private(set) var recentDistance: GoalDistance?
    /// Kept in seconds so a time like 28:30 survives "Change an answer"; `recentMinutes` is what the stepper shows.
    private(set) var recentSeconds: Int?
    var recentMinutes: Int? { recentSeconds.map { $0 / 60 } }

    static let maxUnavailableDays = 4

    init() {}

    /// Starts from earlier answers, so "Change an answer" shows what the user already said.
    init(prefilledWith earlier: InterviewAnswers) {
        answers = earlier
        answered.insert(.goalDistance)
        if earlier.goal.date != nil || earlier.goal.targetTimeSec != nil { answered.insert(.goalDateAndTime) }
        if let result = earlier.recentResult {
            recentDistance = GoalDistance.allCases.first { $0.metres == result.distanceM }
            recentSeconds = result.timeSec
            answered.insert(.recentResult)
        }
        if earlier.weeklyDistanceM != nil { answered.insert(.weeklyDistance) }
        if earlier.longestRunM != nil { answered.insert(.longestRun) }
        if earlier.runningHistory != nil { answered.insert(.history) }
        if earlier.runsPerWeek != nil || earlier.unavailableDays != nil { answered.insert(.runsAndDays) }
        if earlier.longRunDay != nil { answered.insert(.longRunDay) }
        if earlier.pain != nil { answered.insert(.pain) }
        if earlier.strength != nil { answered.insert(.strength) }
        if earlier.targetDisplay != nil { answered.insert(.targetDisplay) }
        if earlier.heartRate != nil { answered.insert(.heartRate) }
    }

    var question: InterviewQuestion { InterviewQuestion.allCases[index] }
    var progress: Double { Double(index + 1) / Double(InterviewQuestion.allCases.count) }
    var progressLabel: String { "Question \(index + 1) of \(InterviewQuestion.allCases.count) · about 2 minutes" }
    var canGoBack: Bool { index > 0 }
    var canContinue: Bool { answered.contains(question) }

    func isAnswered(_ question: InterviewQuestion) -> Bool { answered.contains(question) }

    // MARK: Navigation

    func next() {
        guard canContinue else { return }
        advance()
    }

    func skip() {
        clear(question)
        advance()
    }

    func back() {
        if index > 0 { index -= 1 }
    }

    func buildOwnPlan() {
        wantsBlankPlan = true
        isFinished = true
    }

    private func advance() {
        if index + 1 < InterviewQuestion.allCases.count { index += 1 } else { isFinished = true }
    }

    // MARK: Answers

    func setDistance(_ distance: GoalDistance) {
        answers.goal.distance = distance
        answered.insert(.goalDistance)
    }

    func setGoalDate(_ date: String?) {
        answers.goal.date = date
        refreshGoalDateAndTime()
    }

    func setGoalTimeMinutes(_ minutes: Int?) {
        answers.goal.targetTimeSec = minutes.map { min(max($0 * 60, 600), 21_600) }
        refreshGoalDateAndTime()
    }

    func setRecentResult(distance: GoalDistance? = nil, minutes: Int? = nil) {
        if let distance { recentDistance = distance }
        if let minutes { recentSeconds = max(minutes, 2) * 60 }
        if let d = recentDistance, let seconds = recentSeconds {
            answers.recentResult = .init(distanceM: d.metres, timeSec: min(seconds, 28_800))
            answered.insert(.recentResult)
        }
    }

    func setWeeklyKm(_ km: Int) {
        answers.weeklyDistanceM = min(max(km * 1000, 0), 200_000)
        answered.insert(.weeklyDistance)
    }

    func setLongestRunKm(_ km: Int) {
        answers.longestRunM = min(max(km * 1000, 0), 50_000)
        answered.insert(.longestRun)
    }

    func setHistory(_ history: RunningHistory) {
        answers.runningHistory = history
        answered.insert(.history)
    }

    /// Needs at least that many available days, so it refuses a count the unavailable days leave no room for.
    func setRunsPerWeek(_ runs: Int) {
        let runs = min(max(runs, 3), 5)
        guard runs <= 7 - (answers.unavailableDays?.count ?? 0) else { return }
        answers.runsPerWeek = runs
        answered.insert(.runsAndDays)
    }

    func toggleUnavailable(_ day: Weekday) {
        var days = answers.unavailableDays ?? []
        if let at = days.firstIndex(of: day) {
            days.remove(at: at)
        } else if days.count < Self.maxUnavailableDays, 7 - (days.count + 1) >= (answers.runsPerWeek ?? 0) {
            days.append(day)
            if answers.longRunDay == day {
                answers.longRunDay = nil
                answered.remove(.longRunDay)
            }
        }
        answers.unavailableDays = days.isEmpty ? nil : days
        refreshRunsAndDays()
    }

    func setLongRunDay(_ day: Weekday) {
        guard !(answers.unavailableDays ?? []).contains(day) else { return }
        answers.longRunDay = day
        answered.insert(.longRunDay)
    }

    func setPain(_ pain: Bool) {
        answers.pain = pain
        answered.insert(.pain)
    }

    func setStrength(_ choice: StrengthChoice) {
        answers.strength = .init(enabled: choice != .none, equipment: choice == .none ? nil : choice.rawValue)
        answered.insert(.strength)
    }

    func setTargetDisplay(_ display: TargetDisplay) {
        answers.targetDisplay = display
        answered.insert(.targetDisplay)
    }

    func setMaxHeartRate(_ bpm: Int) {
        answers.heartRate = .init(maxBpm: min(max(bpm, 100), 230))
        answered.insert(.heartRate)
    }

    // MARK: Bookkeeping

    private func refreshGoalDateAndTime() {
        if answers.goal.date != nil || answers.goal.targetTimeSec != nil {
            answered.insert(.goalDateAndTime)
        } else {
            answered.remove(.goalDateAndTime)
        }
    }

    private func refreshRunsAndDays() {
        if answers.runsPerWeek != nil || answers.unavailableDays != nil {
            answered.insert(.runsAndDays)
        } else {
            answered.remove(.runsAndDays)
        }
    }

    private func clear(_ question: InterviewQuestion) {
        answered.remove(question)
        switch question {
        case .goalDistance: answers.goal.distance = .fiveK
        case .goalDateAndTime: answers.goal.date = nil; answers.goal.targetTimeSec = nil
        case .recentResult: answers.recentResult = nil; recentDistance = nil; recentSeconds = nil
        case .weeklyDistance: answers.weeklyDistanceM = nil
        case .longestRun: answers.longestRunM = nil
        case .history: answers.runningHistory = nil
        case .runsAndDays: answers.runsPerWeek = nil; answers.unavailableDays = nil
        case .longRunDay: answers.longRunDay = nil
        case .pain: answers.pain = nil
        case .strength: answers.strength = nil
        case .targetDisplay: answers.targetDisplay = nil
        case .heartRate: answers.heartRate = nil
        }
    }
}
