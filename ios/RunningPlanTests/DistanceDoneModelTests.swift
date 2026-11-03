import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// Distance done and "On track" on Next, Week and Whole (issue #74), from the progress reply.
/// The boards' week 4 ran 5.1 km of 24.9 planned (shown as "25 km"), and week 1 ran 15.2 of 16.
struct DistanceDoneModelTests {
    private static let ran: [Double] = [15.2, 18.5, 20, 5.1, 0, 0, 0, 0, 0, 0]
    private static let cyclingDone = #"{"date":"2026-10-29","type":"custom","title":"Cycling","status":"done","owner":"user","custom":{"activityLabel":"cycling","goal":{"type":"time","value":1800},"effort":"easy"}}"#

    private func schedule(today: String = PlanFixture.today, extra: [String] = []) throws -> PlanSchedule {
        PlanSchedule(plan: try PlanFixture.detail(extra: extra), today: today)
    }

    private func progress(today: String = PlanFixture.today, goal: String = #"{"date":"2026-12-13","daysToGo":46,"onTrack":"on_track"}"#, ran: [Double] = ran) throws -> Components.Schemas.Progress {
        try ProgressFixture.progress(asOf: today, goal: goal, ran: ran)
    }

    // MARK: Next

    @Test func nextShowsDistanceDoneAndFillsTheBarByDistance() throws {
        let m = NextModel(schedule: try schedule(), progress: try progress())
        #expect(m.weekHeader == "5.1 of 25 km · 2 of 6 sessions")
        #expect(m.weekProgress == 5100.0 / 24900.0)
    }

    @Test func nextBarStopsAtFull() throws {
        let m = NextModel(schedule: try schedule(), progress: try progress(ran: [0, 0, 0, 40, 0, 0, 0, 0, 0, 0]))
        #expect(m.weekHeader == "40 of 25 km · 2 of 6 sessions")
        #expect(m.weekProgress == 1)
    }

    @Test func nextWithoutProgressKeepsPlannedAndSessions() throws {
        let m = NextModel(schedule: try schedule(), progress: nil)
        #expect(m.weekHeader == "25 km planned · 2 of 6 sessions")
        #expect(m.weekProgress == 2.0 / 6.0)
    }

    @Test func nextIgnoresAReplyForAnotherPlan() throws {
        let json = String(decoding: ProgressFixture.json(), as: UTF8.self)
            .replacingOccurrences(of: PlanFixture.planID, with: "11111111-1111-4111-8111-111111111111")
        let other = try APIConfiguration.decoder.decode(Components.Schemas.Progress.self, from: Data(json.utf8))
        let m = NextModel(schedule: try schedule(), progress: other)
        #expect(m.weekHeader == "25 km planned · 2 of 6 sessions")
    }

    // MARK: Week

    @Test func weekShowsDistanceDone() throws {
        let m = WeekModel(schedule: try schedule(), week: 3, progress: try progress())
        #expect(m.planned == "25 km planned")
        #expect(m.summary == "5.1 km done")
        #expect(m.progress == 5100.0 / 24900.0)
    }

    @Test func weekAddsCrossTrainingDoneAsMinutes() throws {
        // The Sunday cycling is still planned, so only the Thursday ride that is done counts.
        let m = WeekModel(schedule: try schedule(extra: [Self.cyclingDone]), week: 3, progress: try progress())
        #expect(m.summary == "5.1 km done · plus 30 min cross-training")
    }

    @Test func aFinishedWeekShowsWhatWasRun() throws {
        let m = WeekModel(schedule: try schedule(), week: 0, progress: try progress())
        #expect(m.summary == "15.2 km done")
        #expect(m.progress == 15200.0 / 16000.0)
    }

    @Test func aWeekToComeKeepsTheSessionCount() throws {
        let m = WeekModel(schedule: try schedule(), week: 5, progress: try progress())
        #expect(m.summary.hasSuffix("sessions done"))
    }

    @Test func weekWithoutProgressKeepsSessionsDone() throws {
        let m = WeekModel(schedule: try schedule(), week: 3, progress: nil)
        #expect(m.summary == "2 of 6 sessions done")
        #expect(m.progress == 2.0 / 6.0)
    }

    // MARK: Whole

    @Test func wholeRowsShowRanOverPlannedUpToThisWeek() throws {
        let rows = WholeModel(schedule: try schedule(), progress: try progress()).rows
        #expect(rows.prefix(4).map(\.distance) == ["15.2 / 16 km", "18.5 / 18 km", "20 / 21 km", "5.1 / 25 km"])
        #expect(rows[4].distance == "20 km")
        #expect(rows[9].distance == "16 km")
    }

    @Test func wholeVoiceOverReadsDistanceRun() throws {
        let rows = WholeModel(schedule: try schedule(), progress: try progress()).rows
        #expect(rows[0].spoken == "Week 1, Base, Oct 5, 15.2 of 16 kilometres, done")
        #expect(rows[3].spoken == "Week 4, Build, this week, 5.1 of 25 kilometres")
        #expect(rows[4].spoken == "Week 5, Build, Nov 2, 20 kilometres")
    }

    @Test func theGoalCardShowsTheBadge() throws {
        func badge(_ onTrack: String) throws -> ProgressModel.Badge? {
            WholeModel(schedule: try schedule(), progress: try progress(goal: #"{"date":"2026-12-13","daysToGo":46,"onTrack":"\#(onTrack)"}"#)).goal.badge
        }
        #expect(try badge("on_track") == .onTrack)
        #expect(try badge("behind") == .behind)
        #expect(try badge("unknown") == nil)
    }

    @Test func theGoalBarAlsoCountsPartOfThisWeek() throws {
        let goal = WholeModel(schedule: try schedule(), progress: try progress()).goal
        #expect(goal.progress == (3 + 5100.0 / 24900.0) / 10)
        #expect(goal.doneLabel == "3 weeks done")
    }

    @Test func wholeWithoutProgressChangesNothing() throws {
        let m = WholeModel(schedule: try schedule(), progress: nil)
        #expect(m.rows[3].distance == "25 km")
        #expect(m.goal.badge == nil)
        #expect(m.goal.progress == 0.3)
    }
}
