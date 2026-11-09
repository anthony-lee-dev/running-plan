import APIClient
import Foundation

/// Distance, time and run count per calendar week (Monday to Sunday) and month, from the run summaries the API already
/// stores (issue #137). Pure: `today` is `YYYY-MM-DD`, and runs are bucketed on their `localDate`, never `startedAt`.
/// Counts running workouts that are matched, in the inbox or kept as extra; ignored runs and other workout types are left out.
struct RunTotals: Equatable {
    typealias Activity = Components.Schemas.Activity

    enum Period: String, CaseIterable, Equatable {
        case week, month

        var title: String { self == .week ? "Week" : "Month" }
    }

    struct Bucket: Equatable {
        /// "Oct 26" for a week (its Monday), "Oct" for a month.
        let label: String
        let first: String
        let last: String
        let distanceM: Int
        let timeSec: Int
        let runs: Int
        /// Total time over total distance of the runs that have a distance; nil when none does.
        let paceSecPerKm: Int?
        let isCurrent: Bool
    }

    static let weeksShown = 8
    static let monthsShown = 6

    private let runs: [Activity]
    private let today: String

    init(activities: [Activity], today: String) {
        runs = activities.filter { $0.value1.workoutType == .running && $0.value2.disposition != .ignored }
        self.today = today
    }

    /// The oldest day any shown bucket starts on, so a caller can load only the runs it needs.
    var earliestShown: String {
        let months = monthStarts().first?.first ?? today
        let weeks = weekStarts().first.map { PlanSchedule.date(dayNumber: $0) } ?? today
        return min(months, weeks)
    }

    /// Oldest first; the last bucket holds today.
    func buckets(_ period: Period) -> [Bucket] {
        switch period {
        case .week:
            return weekStarts().enumerated().map { index, start in
                let first = PlanSchedule.date(dayNumber: start)
                let last = PlanSchedule.date(dayNumber: start + 6)
                return bucket(label: PlanPreview.shortDate(first), first: first, last: last, isCurrent: index == Self.weeksShown - 1)
            }
        case .month:
            let starts = monthStarts()
            return starts.enumerated().map { index, month in
                bucket(label: month.label, first: month.first, last: month.last, isCurrent: index == starts.count - 1)
            }
        }
    }

    private func bucket(label: String, first: String, last: String, isCurrent: Bool) -> Bucket {
        // Dates are `YYYY-MM-DD`, so comparing the strings compares the days.
        let inside = runs.filter { $0.value1.localDate >= first && $0.value1.localDate <= last }
        let withDistance = inside.filter { ($0.value1.distanceM ?? 0) > 0 }
        let distance = withDistance.reduce(0) { $0 + ($1.value1.distanceM ?? 0) }
        let paceTime = withDistance.reduce(0) { $0 + $1.value1.durationSec }
        return Bucket(
            label: label, first: first, last: last,
            distanceM: distance,
            timeSec: inside.reduce(0) { $0 + $1.value1.durationSec },
            runs: inside.count,
            paceSecPerKm: distance > 0 ? Int((Double(paceTime) / (Double(distance) / 1000)).rounded()) : nil,
            isCurrent: isCurrent
        )
    }

    /// Day numbers of the Mondays of the shown weeks, oldest first.
    private func weekStarts() -> [Int] {
        let day = PlanPreview.dayNumber(today)
        // 1970-01-01 was a Thursday, three days after a Monday.
        let monday = day - (((day + 3) % 7) + 7) % 7
        return (0..<Self.weeksShown).map { monday - 7 * (Self.weeksShown - 1 - $0) }
    }

    private func monthStarts() -> [(label: String, first: String, last: String)] {
        let parts = today.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return [] }
        return (0..<Self.monthsShown).map { offset in
            let back = Self.monthsShown - 1 - offset
            let index = parts[0] * 12 + (parts[1] - 1) - back
            let year = index / 12, month = index % 12 + 1
            let first = String(format: "%04d-%02d-%02d", year, month, 1)
            let nextFirst = month == 12 ? String(format: "%04d-01-01", year + 1) : String(format: "%04d-%02d-01", year, month + 1)
            let last = PlanSchedule.date(dayNumber: PlanPreview.dayNumber(nextFirst) - 1)
            return (PlanPreview.months[month - 1], first, last)
        }
    }
}

/// What the "Your running" card on Progress shows for one period.
struct RunningStatsModel: Equatable {
    struct Tile: Equatable {
        let value: String
        let label: String
    }

    struct Bar: Equatable {
        let label: String
        /// Distance relative to the biggest period shown, 0 to 1.
        let share: Double
        let isCurrent: Bool
    }

    /// This plan week against the plan: kept apart from the calendar week's totals because a plan's weeks start on
    /// its own start date, and because the server counts only confirmed matches (plus sessions marked done by hand).
    struct PlanWeek: Equatable {
        let title: String
        let plannedKm: Double
        let ranKm: Double
        let sessionsDone: Int
        let sessionsPlanned: Int

        var lines: [String] {
            ["\(PlanPreview.kilometres(ranKm)) of \(PlanPreview.kilometres(plannedKm)) km planned", "\(sessionsDone) of \(sessionsPlanned) sessions done"]
        }
    }

    let period: RunTotals.Period
    let title: String
    let tiles: [Tile]
    /// "2 km more than last week", nil without a run in the period before.
    let comparison: String?
    let isEmpty: Bool
    let emptyNote: String?
    let bars: [Bar]
    let chartSpoken: String
    let planWeek: PlanWeek?

    init(totals: RunTotals, period: RunTotals.Period, planWeek: PlanWeek?) {
        self.period = period
        let buckets = totals.buckets(period)
        let current = buckets.last
        let previous = buckets.count >= 2 ? buckets[buckets.count - 2] : nil
        let noun = period == .week ? "week" : "month"
        title = "This \(noun)"
        isEmpty = (current?.runs ?? 0) == 0
        emptyNote = isEmpty ? "No runs yet this \(noun)." : nil

        var tiles = [
            Tile(value: Self.distance(current?.distanceM ?? 0), label: "Distance"),
            Tile(value: Self.duration(current?.timeSec ?? 0), label: "Time"),
            Tile(value: String(current?.runs ?? 0), label: "Runs"),
        ]
        if let pace = current?.paceSecPerKm { tiles.append(Tile(value: PaceFormat.minutesSeconds(pace) + "/km", label: "Avg pace")) }
        self.tiles = tiles

        if let current, let previous, previous.runs > 0 {
            let difference = (Double(current.distanceM - previous.distanceM) / 100).rounded() / 10
            if difference == 0 {
                comparison = "Same distance as last \(noun)"
            } else {
                comparison = "\(PlanPreview.kilometres(abs(difference))) km \(difference > 0 ? "more" : "less") than last \(noun)"
            }
        } else {
            comparison = nil
        }

        let top = Double(buckets.map(\.distanceM).max() ?? 0)
        bars = buckets.map { Bar(label: $0.label, share: top > 0 ? Double($0.distanceM) / top : 0, isCurrent: $0.isCurrent) }

        var spoken = ["Distance run per \(noun)."]
        for bucket in buckets {
            let name = bucket.isCurrent ? "\(bucket.label), this \(noun)" : bucket.label
            let runs = bucket.runs == 1 ? "1 run" : "\(bucket.runs) runs"
            spoken.append("\(name): \(Self.distance(bucket.distanceM)) in \(runs).")
        }
        chartSpoken = spoken.joined(separator: " ")
        self.planWeek = period == .week ? planWeek : nil
    }

    static func distance(_ metres: Int) -> String {
        PlanPreview.kilometres((Double(metres) / 100).rounded() / 10) + " km"
    }

    /// "45 min", "1 h 00 min": rounded to the minute.
    static func duration(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h " + String(format: "%02d", minutes % 60) + " min"
    }

    /// This plan week, when the plan is under way and the progress reply is for it.
    static func planWeek(schedule: PlanSchedule, done: DistanceDone?) -> PlanWeek? {
        guard let done, case .week(let index) = schedule.position else { return nil }
        return PlanWeek(
            title: "Plan week \(index + 1)",
            plannedKm: schedule.plannedMetres(week: index) / 1000,
            ranKm: done.ran(week: index) / 1000,
            sessionsDone: schedule.doneCount(week: index),
            sessionsPlanned: schedule.sessionCount(week: index)
        )
    }
}
