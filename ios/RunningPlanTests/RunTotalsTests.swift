import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct RunTotalsTests {
    private func run(_ id: String, _ date: String, km: Int? = 5, sec: Int = 1800, type: String = "running", disposition: String = "matched") throws -> Components.Schemas.Activity {
        try activityFixture(id: id, date: date, type: type, durationSec: sec, distanceM: km.map { $0 * 1000 }, disposition: disposition)
    }

    // 2026-11-04 is a Wednesday; its calendar week is Mon 2026-11-02 to Sun 2026-11-08.
    private let today = "2026-11-04"

    @Test func weeksRunMondayToSundayOnTheLocalDate() throws {
        let runs = [
            try run("a", "2026-11-02"), // Monday, this week
            try run("b", "2026-11-08"), // Sunday, this week
            try run("c", "2026-11-01"), // Sunday, last week
            try run("d", "2026-10-26"), // Monday, last week
        ]
        let weeks = RunTotals(activities: runs, today: today).buckets(.week)
        #expect(weeks.count == RunTotals.weeksShown)
        let this = try #require(weeks.last)
        let last = weeks[weeks.count - 2]
        #expect(this.first == "2026-11-02")
        #expect(this.last == "2026-11-08")
        #expect(this.isCurrent)
        #expect(this.runs == 2)
        #expect(this.distanceM == 10_000)
        #expect(last.first == "2026-10-26")
        #expect(last.runs == 2)
        #expect(!last.isCurrent)
    }

    @Test func monthsAreCalendarMonthsAndOldestComesFirst() throws {
        let runs = [try run("a", "2026-11-01"), try run("b", "2026-10-31"), try run("c", "2026-10-01")]
        let months = RunTotals(activities: runs, today: today).buckets(.month)
        #expect(months.count == RunTotals.monthsShown)
        #expect(months.map(\.label).suffix(2) == ["Oct", "Nov"])
        #expect(months.last?.runs == 1)
        #expect(months[months.count - 2].runs == 2)
        #expect(months.last?.first == "2026-11-01")
        #expect(months.last?.last == "2026-11-30")
        #expect(months.first?.first == "2026-06-01")
    }

    @Test func monthsCrossTheYear() throws {
        let months = RunTotals(activities: [try run("a", "2025-12-31")], today: "2026-02-10").buckets(.month)
        #expect(months.map(\.label).suffix(3) == ["Dec", "Jan", "Feb"])
        #expect(months[months.count - 3].runs == 1)
        #expect(months[months.count - 3].last == "2025-12-31")
    }

    @Test func onlyRunsThatCountAreCounted() throws {
        let runs = [
            try run("a", "2026-11-03"),
            try run("b", "2026-11-03", disposition: "inbox"),
            try run("c", "2026-11-03", disposition: "extra"),
            try run("d", "2026-11-03", disposition: "ignored"),
            try run("e", "2026-11-03", type: "cycling"),
        ]
        let this = try #require(RunTotals(activities: runs, today: today).buckets(.week).last)
        #expect(this.runs == 3)
    }

    @Test func paceIsTotalTimeOverTotalDistanceOfRunsWithADistance() throws {
        let runs = [
            try run("a", "2026-11-03", km: 5, sec: 1500), // 5:00/km
            try run("b", "2026-11-04", km: 10, sec: 3600), // 6:00/km
            try run("c", "2026-11-05", km: nil, sec: 600), // no distance: time and count only
        ]
        let this = try #require(RunTotals(activities: runs, today: today).buckets(.week).last)
        #expect(this.runs == 3)
        #expect(this.distanceM == 15_000)
        #expect(this.timeSec == 5700)
        // (1500 + 3600) s over 15 km = 340 s/km.
        #expect(this.paceSecPerKm == 340)
    }

    @Test func noDistanceMeansNoPace() throws {
        let this = try #require(RunTotals(activities: [try run("a", "2026-11-03", km: nil)], today: today).buckets(.week).last)
        #expect(this.paceSecPerKm == nil)
        let empty = try #require(RunTotals(activities: [], today: today).buckets(.week).last)
        #expect(empty.runs == 0)
        #expect(empty.paceSecPerKm == nil)
    }

    @Test func runsOutsideTheShownBucketsAreLeftOut() throws {
        let weeks = RunTotals(activities: [try run("a", "2025-01-01"), try run("b", "2026-11-09")], today: today).buckets(.week)
        #expect(weeks.reduce(0) { $0 + $1.runs } == 0)
    }

    @Test func earliestShownDayLetsACallerLoadOnlyWhatItNeeds() {
        let totals = RunTotals(activities: [], today: today)
        #expect(totals.earliestShown == "2026-06-01") // six months back covers the eight weeks
    }
}

struct RunningStatsModelTests {
    private func run(_ id: String, _ date: String, km: Int, sec: Int) throws -> Components.Schemas.Activity {
        try activityFixture(id: id, date: date, durationSec: sec, distanceM: km * 1000, disposition: "matched")
    }

    private let today = "2026-11-04"

    @Test func thisWeekShowsTotalsAndHowItComparesWithLastWeek() throws {
        let runs = [try run("a", "2026-11-03", km: 10, sec: 3600), try run("b", "2026-10-28", km: 8, sec: 2880)]
        let model = RunningStatsModel(totals: RunTotals(activities: runs, today: today), period: .week, planWeek: nil)
        #expect(model.title == "This week")
        #expect(model.tiles.map(\.label) == ["Distance", "Time", "Runs", "Avg pace"])
        #expect(model.tiles.map(\.value) == ["10 km", "1 h 00 min", "1", "6:00/km"])
        #expect(model.comparison == "2 km more than last week")
    }

    @Test func aMonthIsNamedAndCompared() throws {
        let runs = [try run("a", "2026-11-03", km: 10, sec: 3600), try run("b", "2026-10-28", km: 30, sec: 10800)]
        let model = RunningStatsModel(totals: RunTotals(activities: runs, today: today), period: .month, planWeek: nil)
        #expect(model.title == "This month")
        #expect(model.comparison == "20 km less than last month")
    }

    @Test func noComparisonWithoutARunInThePreviousPeriod() throws {
        let model = RunningStatsModel(totals: RunTotals(activities: [try run("a", "2026-11-03", km: 5, sec: 1800)], today: today), period: .week, planWeek: nil)
        #expect(model.comparison == nil)
    }

    @Test func aPeriodWithNoRunsSaysSoAndHidesPace() {
        let model = RunningStatsModel(totals: RunTotals(activities: [], today: today), period: .week, planWeek: nil)
        #expect(model.tiles.map(\.label) == ["Distance", "Time", "Runs"])
        #expect(model.tiles.first?.value == "0 km")
        #expect(model.isEmpty)
        #expect(model.emptyNote == "No runs yet this week.")
    }

    @Test func barsScaleToTheBiggestPeriod() throws {
        let runs = [try run("a", "2026-11-03", km: 10, sec: 3600), try run("b", "2026-10-28", km: 20, sec: 7200)]
        let model = RunningStatsModel(totals: RunTotals(activities: runs, today: today), period: .week, planWeek: nil)
        #expect(model.bars.count == RunTotals.weeksShown)
        #expect(model.bars.last?.share == 0.5)
        #expect(model.bars[model.bars.count - 2].share == 1)
        #expect(model.bars.first?.share == 0)
        #expect(model.bars.last?.isCurrent == true)
    }

    @Test func theSpokenSummaryNamesEveryPeriod() throws {
        let model = RunningStatsModel(totals: RunTotals(activities: [try run("a", "2026-11-03", km: 10, sec: 3600)], today: today), period: .week, planWeek: nil)
        #expect(model.chartSpoken.hasPrefix("Distance run per week."))
        #expect(model.chartSpoken.contains("10 km in 1 run"))
    }

    @Test func planWeekShowsOnlyForTheWeekPeriod() {
        let plan = RunningStatsModel.PlanWeek(title: "Plan week 4", plannedKm: 25, ranKm: 18.5, sessionsDone: 3, sessionsPlanned: 5)
        let week = RunningStatsModel(totals: RunTotals(activities: [], today: today), period: .week, planWeek: plan)
        let month = RunningStatsModel(totals: RunTotals(activities: [], today: today), period: .month, planWeek: plan)
        #expect(week.planWeek?.lines == ["18.5 of 25 km planned", "3 of 5 sessions done"])
        #expect(month.planWeek == nil)
    }

    @Test func durationReadsAsMinutesThenHours() {
        #expect(RunningStatsModel.duration(0) == "0 min")
        #expect(RunningStatsModel.duration(59 * 60 + 40) == "1 h 00 min")
        #expect(RunningStatsModel.duration(45 * 60) == "45 min")
        #expect(RunningStatsModel.duration(3 * 3600 + 12 * 60) == "3 h 12 min")
    }
}
