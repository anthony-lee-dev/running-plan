import APIClient
import Foundation

/// Everything DK-Progress shows, from the progress endpoint's reply and the plan (for the goal's name, the weeks and
/// which week is this one). Pure. The board's pace sentence ("Your easy runs are landing right in range") and its
/// longest-run win need per-run detail the endpoint does not give, so the goal card speaks about adherence and the win
/// card about the biggest week run, both from the reply.
struct ProgressModel: Equatable {
    enum Badge: Equatable {
        case onTrack, behind

        var title: String {
            switch self {
            case .onTrack: "On track"
            case .behind: "Behind"
            }
        }
    }

    struct Goal: Equatable {
        /// "Goal: 10K in 55:00", or "Your plan" without a goal.
        let title: String
        /// "46 days", "Race day", "Race done", "Plan done".
        let countdown: String
        /// "to race day, Sunday Dec 13".
        let detail: String
        let badge: Badge?
        let note: String
    }

    struct Tile: Equatable {
        let value: String
        let label: String
        let detail: String
    }

    struct Bar: Equatable {
        let week: Int
        let label: String
        let plannedKm: Double
        /// Nil before the first week is over: planned bars only.
        let ranKm: Double?
        let isCurrent: Bool
    }

    /// Weeks shown at most, so the chart fits a phone's width: the most recent ones.
    static let maxBars = 8

    let headline: String
    let goal: Goal
    let sessions: Tile
    let keyRuns: Tile
    let strength: Tile
    let bars: [Bar]
    /// Shown under the chart before the first week is over.
    let firstWeekNote: String?
    /// "A win worth noticing", when the latest finished week was the biggest so far.
    let win: String?
    let chartSpoken: String

    init(progress: Components.Schemas.Progress, plan: Components.Schemas.PlanDetail) {
        let schedule = PlanSchedule(plan: plan, today: progress.asOf)
        let adherence = progress.adherence
        let judged = adherence.done + adherence.skipped + adherence.missed
        let doneOfDue = "You've done \(adherence.done) of the \(adherence.due) sessions due so far."

        // Weeks finished, and the last week the chart reaches.
        let finishedWeeks: Int
        let lastWeek: Int
        let current: Int?
        switch schedule.position {
        case .notStarted(let start):
            finishedWeeks = 0
            lastWeek = 0
            current = nil
            headline = "Your plan starts \(NextModel.weekday(start)), \(PlanPreview.shortDate(start))."
        case .week(let index):
            finishedWeeks = index
            lastWeek = index
            current = index
            if index == 0 {
                headline = "Your first week is under way."
            } else {
                // The server's on-track share: done of the sessions judged (today's still to do are not yet missed).
                let steady = judged > 0 && Double(adherence.done) / Double(judged) >= 0.7
                let count = Self.word(index)
                let weeks = index == 1 ? "week" : "weeks"
                headline = steady
                    ? "\(count) steady \(weeks) in. You've been showing up, and it's adding up."
                    : "\(count) \(weeks) in. Every session you do counts, so pick up with the next one."
            }
        case .finished:
            finishedWeeks = schedule.weekCount
            lastWeek = max(schedule.weekCount - 1, 0)
            current = nil
            headline = "Plan finished. Look back at how far you've come."
        }

        let badge: Badge? = switch progress.goal.onTrack {
        case .on_track: .onTrack
        case .behind: .behind
        case .unknown: nil
        }
        let note: String = switch badge {
        case .onTrack: doneOfDue + " Keep it steady."
        case .behind: doneOfDue + " Missed a few? That's fine: pick up with the next one."
        case nil: judged < 3 ? "A few more sessions and we can say how it's going." : doneOfDue
        }
        let planGoal = plan.value1.value2.goal
        let (countdown, detail) = Self.countdown(progress: progress, schedule: schedule)
        goal = Goal(
            title: planGoal._type == .none ? "Your plan" : "Goal: \(WholeModel.title(planGoal))",
            countdown: countdown, detail: detail, badge: badge, note: note
        )

        sessions = Tile(
            value: adherence.due > 0 ? "\(adherence.done * 100 / adherence.due)%" : "0%",
            label: "Sessions done",
            detail: adherence.due > 0 ? "\(adherence.done) of \(adherence.due)" : "None due yet"
        )
        keyRuns = Tile(
            value: "\(progress.keySessions.completed) of \(progress.keySessions.planned)",
            label: "Key runs",
            detail: progress.keySessions.planned > 0 ? Self.keyKinds(schedule.sessions) : "None due yet"
        )
        strength = Tile(
            value: "\(progress.strengthSessions.completed) of \(progress.strengthSessions.planned)",
            label: "Strength",
            detail: "Counted apart"
        )

        let showsRan = finishedWeeks > 0
        let weeks = progress.weeks.sorted { $0.index < $1.index }
        bars = weeks
            .filter { $0.index <= lastWeek && $0.index > lastWeek - Self.maxBars }
            .map { week in
                Bar(
                    week: week.index,
                    label: "W\(week.index + 1)",
                    plannedKm: Self.km(week.plannedDistanceM),
                    ranKm: showsRan ? Self.km(week.actualDistanceM) : nil,
                    isCurrent: week.index == current
                )
            }
        firstWeekNote = showsRan ? nil : "Your first week's progress appears on your review day."

        let finished = weeks.filter { $0.index < finishedWeeks }
        if finished.count >= 2, let latest = finished.last, latest.actualDistanceM > 0,
           finished.dropLast().allSatisfy({ $0.actualDistanceM < latest.actualDistanceM }) {
            win = "Week \(latest.index + 1) was your biggest week yet: \(PlanPreview.kilometres(Self.km(latest.actualDistanceM))) km run."
        } else {
            win = nil
        }

        var spoken = ["Running volume in kilometres per week."]
        for bar in bars {
            let name = bar.isCurrent ? "Week \(bar.week + 1), this week" : "Week \(bar.week + 1)"
            let ran = bar.ranKm.map { ", \(PlanPreview.kilometres($0)) run" } ?? ""
            spoken.append("\(name): \(PlanPreview.kilometres(bar.plannedKm)) planned\(ran).")
        }
        chartSpoken = spoken.joined(separator: " ")
    }

    private static func km(_ metres: Int) -> Double {
        (Double(metres) / 100).rounded() / 10
    }

    private static func countdown(progress: Components.Schemas.Progress, schedule: PlanSchedule) -> (String, String) {
        func day(_ date: String) -> String { "\(NextModel.weekday(date)) \(PlanPreview.shortDate(date))" }
        func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
        if let race = progress.goal.date {
            guard let left = progress.goal.daysToGo else { return ("Race done", "Race day was \(day(race))") }
            return left == 0 ? ("Race day", "Today, \(day(race))") : (days(left), "to race day, \(day(race))")
        }
        let end = schedule.weekRange(max(schedule.weekCount - 1, 0)).last
        let left = PlanPreview.dayNumber(end) - PlanPreview.dayNumber(progress.asOf)
        if left < 0 { return ("Plan done", "Your plan ended \(day(end))") }
        return left == 0 ? ("Last day", "of your plan, \(day(end))") : (days(left), "to the end of your plan, \(day(end))")
    }

    /// "Long and intervals": the kinds of key session in the plan, longest-effort first.
    private static func keyKinds(_ sessions: [PlanSchedule.Session]) -> String {
        let order: [Components.Schemas.SessionType] = [.long, .tempo, .intervals, .easy, .strength, .custom]
        let names: [Components.Schemas.SessionType: String] = [.long: "long", .tempo: "tempo", .intervals: "intervals", .easy: "easy", .strength: "strength", .custom: "other"]
        let kinds = Set(sessions.filter { $0.value2.key == true && $0.value2._type != .rest }.map(\.value2._type))
        let words = order.filter(kinds.contains).compactMap { names[$0] }
        guard let first = words.first else { return "Long runs and hard sessions" }
        let joined = words.count == 1 ? first : words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static func word(_ n: Int) -> String {
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
        return n < words.count ? words[n] : String(n)
    }
}
