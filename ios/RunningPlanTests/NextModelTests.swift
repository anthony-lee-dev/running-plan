import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct SessionSummaryTests {
    private func session(on date: String) throws -> Components.Schemas.SessionContent {
        try #require(PlanSchedule(plan: try PlanFixture.detail(), today: PlanFixture.today).sessions.first { $0.value2.date == date }).value2
    }

    @Test func intervalsShowTimeDistanceAndTheFastRepPace() throws {
        let s = try session(on: "2026-10-28")
        #expect(SessionSummary.detail(s) == "About 43 min · 6.9 km · fast reps at 5:15–5:30/km")
        #expect(SessionSummary.effort(s) == "Hard but controlled")
    }

    @Test func runsShowDistanceAndPaceRange() throws {
        let s = try session(on: "2026-10-30")
        #expect(SessionSummary.detail(s) == "About 34 min · 5 km · 6:25–7:10/km")
        #expect(SessionSummary.detail(s, withTime: false) == "5 km · 6:25–7:10/km")
        #expect(SessionSummary.effort(s) == "Easy")
    }

    @Test func strengthAndCrossTrainingShowTime() throws {
        #expect(SessionSummary.detail(try session(on: "2026-10-27")) == "20 min · strength")
        #expect(SessionSummary.detail(try session(on: "2026-11-01")) == "45 min · easy effort")
    }

    @Test func theShapeIsTheStepsInOrderSizedByTime() throws {
        let shape = SessionSummary.shape(try session(on: "2026-10-28"))
        #expect(shape.map(\.intensity) == [.easy] + Array(repeating: [.hard, .recovery], count: 5).flatMap { $0 } + [.easy])
        #expect(abs(shape.reduce(0) { $0 + $1.seconds } - SessionSummary.estimatedSeconds(try session(on: "2026-10-28"))) < 1)
        #expect(SessionSummary.shape(try session(on: "2026-10-30")).map(\.intensity) == [.easy])
        #expect(SessionSummary.shape(try session(on: "2026-10-27")).isEmpty, "strength has no run shape")
    }
}

struct NextModelTests {
    private func model(today: String = PlanFixture.today, extra: [String] = []) throws -> NextModel {
        NextModel(schedule: PlanSchedule(plan: try PlanFixture.detail(extra: extra), today: today))
    }

    @Test func theBoardsDay() throws {
        let m = try model()
        #expect(m.eyebrow == "Wednesday, Oct 28 · Week 4 of 10 · Build")
        #expect(m.focus?.label == "TODAY")
        #expect(m.focus?.title == "Intervals: 5 × 600 m")
        #expect(m.focus?.effort == "Hard but controlled")
        #expect(m.weekHeader == "25 km planned · 2 of 6 sessions")
        #expect(m.weekProgress == 2.0 / 6.0)
        #expect(m.nextUp == "Next up: Easy run, Friday · 5 km")
    }

    @Test func theWeekStripMarksDoneTodayRestAndPlannedDays() throws {
        let days = try model().week
        #expect(days.map(\.letter) == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(days.map(\.state) == [.done, .done, .today("28"), .rest, .planned("30"), .planned("31"), .planned("1")])
    }

    @Test func onARestDayTheCardShowsTheNextSession() throws {
        let m = try model(today: "2026-10-29")
        #expect(m.focus?.label == "NEXT UP · FRIDAY")
        #expect(m.focus?.title == "Easy run")
        #expect(m.week[3].state == .todayRest)
        #expect(m.nextUp == nil, "the card already shows it")
    }

    @Test func aSkippedDayIsMarked() throws {
        let skipped = #"{"date":"2026-10-29","type":"easy","title":"Easy run","status":"skipped","owner":"user","steps":[{"kind":"work","goal":{"type":"distance","value":3000}}]}"#
        #expect(try model(extra: [skipped]).week[3].state == .skipped)
    }

    @Test func beforeTheStartTheFirstSessionIsShown() throws {
        let m = try model(today: "2026-10-01")
        #expect(m.eyebrow == "Thursday, Oct 1 · Starts Monday, Oct 5")
        #expect(m.focus?.label == "FIRST SESSION · MONDAY, OCT 5")
        #expect(m.week.isEmpty)
    }

    @Test func afterTheEndThereIsNothingToDo() throws {
        let m = try model(today: "2026-12-20")
        #expect(m.eyebrow == "Sunday, Dec 20 · Plan finished")
        #expect(m.focus == nil)
        #expect(m.week.isEmpty)
    }
}
