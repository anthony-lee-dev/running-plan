import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct WholeModelTests {
    private func model(today: String = PlanFixture.today) throws -> WholeModel {
        WholeModel(schedule: PlanSchedule(plan: try PlanFixture.detail(), today: today))
    }

    @Test func oneRowPerWeekLikeTheBoard() throws {
        let rows = try model().rows
        #expect(rows.map(\.label) == (1...10).map { "W\($0)" })
        #expect(rows[0].detail == "Base · Oct 5")
        #expect(rows[3].detail == "Build · This week")
        #expect(rows[4].detail == "Build · Nov 2 · lighter week")
        #expect(rows[9].detail == "Taper · Dec 7 · race week")
        #expect(rows.map(\.distance) == ["16 km", "18 km", "21 km", "25 km", "20 km", "28 km", "31 km", "33 km", "24 km", "16 km"])
    }

    @Test func onlyAPlanWithARaceHasARaceWeek() throws {
        let noRace = WholeModel(schedule: PlanSchedule(plan: try PlanFixture.detail(goal: #"{"type":"none"}"#), today: PlanFixture.today))
        #expect(noRace.rows[9].detail == "Taper · Dec 7")
        let undated = WholeModel(schedule: PlanSchedule(plan: try PlanFixture.detail(goal: #"{"type":"10k"}"#), today: PlanFixture.today))
        #expect(undated.rows[9].detail == "Taper · Dec 7")
    }

    @Test func doneWeeksAreTickedAndThisWeekStandsOut() throws {
        let rows = try model().rows
        // Built step by step: as one inline expression it is too slow to type-check on the CI runner.
        let expected: [WholeModel.State] = [.done, .done, .done, .current] + Array(repeating: WholeModel.State.upcoming, count: 6)
        #expect(rows.map(\.state) == expected)
    }

    @Test func noWeekIsCurrentBeforeTheStartOrAfterTheEnd() throws {
        #expect(!(try model(today: "2026-10-01")).rows.contains { $0.state == .current })
        #expect(!(try model(today: "2027-01-01")).rows.contains { $0.state == .current })
    }

    @Test func voiceOverReadsEachWeekAsOneSentence() throws {
        let rows = try model().rows
        #expect(rows[0].spoken == "Week 1, Base, Oct 5, 16 kilometres, done")
        #expect(rows[3].spoken == "Week 4, Build, this week, 25 kilometres")
    }

    @Test func theGoalCardLikeTheBoard() throws {
        let goal = try model().goal
        #expect(goal.title == "10K in 55:00")
        #expect(goal.subtitle == "Race day Sunday, Dec 13 · 46 days to go")
        #expect(goal.weekLabel == "Week 4 of 10")
        #expect(goal.doneLabel == "3 weeks done")
        #expect(goal.progress == 0.3)
    }

    @Test func goalsWithoutATimeOrDateOrRace() throws {
        func goal(_ json: String, today: String = PlanFixture.today) throws -> WholeModel.Goal {
            WholeModel(schedule: PlanSchedule(plan: try PlanFixture.detail(goal: json), today: today)).goal
        }
        #expect(try goal(#"{"type":"half_marathon","date":"2026-12-13","targetTimeSec":6300}"#).title == "Half marathon in 1:45:00")
        #expect(try goal(#"{"type":"10k","date":"2026-12-13"}"#).title == "10K")
        #expect(try goal(#"{"type":"10k"}"#).subtitle == "Ends Sunday, Dec 13")
        #expect(try goal(#"{"type":"none"}"#).title == "Your plan")
        #expect(try goal(#"{"type":"custom","label":"Trail 15K","date":"2026-12-13"}"#).title == "Trail 15K")
        #expect(try goal(PlanFixture.goal, today: "2026-12-13").subtitle == "Race day Sunday, Dec 13 · today")
        #expect(try goal(PlanFixture.goal, today: "2026-12-12").subtitle == "Race day Sunday, Dec 13 · 1 day to go")
    }

    @Test func beforeTheStartAndAfterTheEnd() throws {
        let before = try model(today: "2026-10-01").goal
        #expect(before.weekLabel == "Starts Oct 5")
        #expect(before.doneLabel == "0 weeks done")
        #expect(before.progress == 0)
        let after = try model(today: "2027-01-01").goal
        #expect(after.weekLabel == "Plan finished")
        #expect(after.doneLabel == "10 weeks done")
        #expect(after.progress == 1)
    }

    @Test func theChartHasABarPerWeekWithThisWeekMarked() throws {
        let bars = try model().bars
        #expect(bars.map(\.kilometres) == [16, 18, 21, 24.9, 20, 28, 31, 33, 24, 16])
        #expect(bars.map(\.isCurrent) == [false, false, false, true, false, false, false, false, false, false])
        let ahead: [Bool] = [false, false, false, false] + Array(repeating: true, count: 6)
        #expect(bars.map(\.isAhead) == ahead)
        #expect(bars[3].phase == .build)
        #expect(try model().chartSpoken == "Weekly distance for the 10-week plan. Weeks 1 to 3 done, week 4 this week, longest week 33 km.")
    }
}
