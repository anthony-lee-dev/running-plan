import APIClient
import Foundation
@testable import RunningPlan

/// A `GET /v1/plans/{id}/progress` reply shaped like DK-Progress, for `PlanFixture`'s plan on the boards' today
/// (Wed 2026-10-28, week 4): 23 of 25 sessions done, 5 of 6 key runs, 5 of 6 strength sessions, on track, 46 days to
/// the race. Weeks 1 to 4 planned 16, 18, 21 and 25 km and ran 15.3, 18.5, 20 and 5 km; the rest are still to come.
enum ProgressFixture {
    static let plannedKm: [Double] = PlanFixture.weeklyKm
    static let ranKm: [Double] = [15.3, 18.5, 20, 5, 0, 0, 0, 0, 0, 0]

    struct Adherence {
        var due = 25
        var done = 23
        var skipped = 1
        var missed = 1
    }

    static func json(
        asOf: String = PlanFixture.today, adherence: Adherence = Adherence(), key: (Int, Int) = (6, 5), strength: (Int, Int) = (6, 5),
        goal: String = #"{"date":"2026-12-13","daysToGo":46,"onTrack":"on_track"}"#, ran: [Double] = ranKm
    ) -> Data {
        let weeks = plannedKm.indices.map { index in
            let planned = Int(plannedKm[index] * 1000)
            let actual = Int(ran[index] * 1000)
            return #"{"index":\#(index),"plannedDistanceM":\#(planned),"actualDistanceM":\#(actual),"plannedTimeSec":\#(planned * 2 / 5),"actualTimeSec":\#(actual * 2 / 5)}"#
        }.joined(separator: ",")
        return Data(#"""
        {"planId":"\#(PlanFixture.planID)","asOf":"\#(asOf)",
         "adherence":{"due":\#(adherence.due),"done":\#(adherence.done),"skipped":\#(adherence.skipped),"missed":\#(adherence.missed)},
         "weeks":[\#(weeks)],
         "keySessions":{"planned":\#(key.0),"completed":\#(key.1)},
         "strengthSessions":{"planned":\#(strength.0),"completed":\#(strength.1)},
         "goal":\#(goal)}
        """#.utf8)
    }

    static func progress(
        asOf: String = PlanFixture.today, adherence: Adherence = Adherence(), key: (Int, Int) = (6, 5), strength: (Int, Int) = (6, 5),
        goal: String = #"{"date":"2026-12-13","daysToGo":46,"onTrack":"on_track"}"#, ran: [Double] = ranKm
    ) throws -> Components.Schemas.Progress {
        try APIConfiguration.decoder.decode(
            Components.Schemas.Progress.self,
            from: json(asOf: asOf, adherence: adherence, key: key, strength: strength, goal: goal, ran: ran)
        )
    }

    /// The board's screen: `PlanFixture`'s plan with this reply.
    static func model(asOf: String = PlanFixture.today, goal: String = PlanFixture.goal, progress: Components.Schemas.Progress? = nil) throws -> ProgressModel {
        ProgressModel(progress: try progress ?? Self.progress(asOf: asOf), plan: try PlanFixture.detail(goal: goal))
    }
}
