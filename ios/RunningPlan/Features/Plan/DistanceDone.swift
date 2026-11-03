import APIClient
import Foundation

/// Distance actually run, per plan week, from `GET /v1/plans/{id}/progress` (issue #74). Pure: the Next, Week and Whole
/// models take an optional one and keep their planned-only text when there is none (not loaded yet, failed, or a reply
/// for another plan).
struct DistanceDone {
    private let ranMetres: [Int: Int]
    let schedule: PlanSchedule
    let onTrack: Components.Schemas.Progress.goalPayload.onTrackPayload

    init?(progress: Components.Schemas.Progress?, schedule: PlanSchedule) {
        guard let progress, progress.planId.lowercased() == schedule.plan.value1.value1.id.lowercased() else { return nil }
        ranMetres = Dictionary(progress.weeks.map { ($0.index, $0.actualDistanceM) }, uniquingKeysWith: { first, _ in first })
        onTrack = progress.goal.onTrack
        self.schedule = schedule
    }

    /// The last week with something to show: this week, every week once the plan is over, none before it starts.
    var lastShownWeek: Int? {
        switch schedule.position {
        case .week(let index): index
        case .finished: schedule.weekCount - 1
        case .notStarted: nil
        }
    }

    func shows(week: Int) -> Bool {
        guard let last = lastShownWeek else { return false }
        return week <= last
    }

    func ran(week: Int) -> Double { Double(ranMetres[week] ?? 0) }

    /// Share of the week's planned distance run, 0 to 1; nil when the week plans no distance.
    func fraction(week: Int) -> Double? {
        let planned = schedule.plannedMetres(week: week)
        guard planned > 0 else { return nil }
        return min(ran(week: week) / planned, 1)
    }

    /// Minutes of the user's own cross-training marked done in the week (a run's distance is in the progress reply, this
    /// is not: it comes from the sessions).
    func crossTrainingMinutes(week: Int) -> Int {
        let seconds = schedule.sessions(inWeek: week).reduce(0) { total, session in
            let s = session.value2
            guard s._type == .custom, s.status == .done, s.custom?.goal?._type == .time else { return total }
            return total + (s.custom?.goal?.value ?? 0)
        }
        return Int((Double(seconds) / 60).rounded())
    }
}
