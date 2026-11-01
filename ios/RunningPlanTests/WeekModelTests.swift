import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct WeekModelTests {
    private func schedule(today: String = PlanFixture.today, extra: [String] = []) throws -> PlanSchedule {
        PlanSchedule(plan: try PlanFixture.detail(extra: extra), today: today)
    }

    @Test func itOpensOnThisWeek() throws {
        #expect(WeekModel.initialWeek(try schedule()) == 3)
        #expect(WeekModel.initialWeek(try schedule(today: "2026-10-01")) == 0, "before the start: week 1")
        #expect(WeekModel.initialWeek(try schedule(today: "2027-01-01")) == 9, "after the end: the last week")
    }

    @Test func aPlanThatHasNotStartedShowsWeekOneWithNothingToday() throws {
        let s = try schedule(today: "2026-09-20")
        let m = WeekModel(schedule: s, week: WeekModel.initialWeek(s))
        #expect(m.title.hasPrefix("Week 1"))
        #expect(!m.canGoBack)
        #expect(m.addDate == "2026-10-05", "Add a session starts on the plan's first day, not a day before the plan")
        #expect(!m.days.contains { $0.weekday == "TODAY" })
    }

    @Test func theBoardsWeek() throws {
        let m = WeekModel(schedule: try schedule(), week: 3)
        #expect(m.title == "Week 4 · Build")
        #expect(m.range == "Oct 26 – Nov 1")
        #expect(m.canGoBack && m.canGoForward)
        #expect(m.planned == "25 km planned")
        // Sessions count the user's cycling too; distance done waits for the progress endpoint (2.15).
        #expect(m.summary == "2 of 6 sessions done")
        #expect(m.progress == 2.0 / 6.0)
    }

    @Test func theBoardsDays() throws {
        let days = WeekModel(schedule: try schedule(), week: 3).days
        #expect(days.map(\.weekday) == ["MON", "TUE", "TODAY", "THU", "FRI", "SAT", "SUN"])
        #expect(days.map(\.number) == ["26", "27", "28", "29", "30", "31", "1"])
        #expect(days.map(\.isRest) == [false, false, false, true, false, false, false])

        let items = days.map(\.items.first)
        #expect(items[0]?.title == "Easy run")
        #expect(items[0]?.detail == "5 km · 6:25–7:10/km")
        #expect(items[0]?.trailing == .done)
        #expect(items[1]?.trailing == .done)
        #expect(items[2]?.detail == "About 43 min · 6.9 km · fast reps at 5:15–5:30/km")
        #expect(items[2]?.trailing == .today)
        #expect(items[2]?.isToday == true)
        #expect(items[0]?.isToday == false)
        #expect(items[2]?.shape.isEmpty == false)
        #expect(items[4]?.trailing == .badge(.easy))
        #expect(items[4]?.shape.isEmpty == true, "only today's card shows the workout shape")
        #expect(items[5]?.trailing == .badge(.long))
        #expect(items[6]?.title == "Cycling")
        #expect(items[6]?.detail == "45 min · easy effort")
        #expect(items[6]?.trailing == .badge(.yours))
    }

    @Test func aSkippedSessionSaysSo() throws {
        let skipped = #"{"date":"2026-10-29","type":"easy","title":"Easy run","status":"skipped","owner":"user","steps":[{"kind":"work","goal":{"type":"distance","value":3000}}]}"#
        let day = WeekModel(schedule: try schedule(extra: [skipped]), week: 3).days[3]
        #expect(!day.isRest)
        #expect(day.items.first?.trailing == .skipped)
    }

    @Test func theFirstAndLastWeeksStopTheArrows() throws {
        let s = try schedule()
        #expect(!WeekModel(schedule: s, week: 0).canGoBack)
        #expect(!WeekModel(schedule: s, week: 9).canGoForward)
        let first = WeekModel(schedule: s, week: 0)
        #expect(first.title == "Week 1 · Base")
        #expect(first.range == "Oct 5 – Oct 11")
        #expect(first.summary == "5 of 5 sessions done")
        #expect(first.days.allSatisfy { $0.weekday != "TODAY" })
    }

    @Test func voiceOverReadsADayAsOneSentence() throws {
        let days = WeekModel(schedule: try schedule(), week: 3).days
        #expect(days[0].spoken == "Monday 26: Easy run, 5 km · 6 minutes 25 to 7 minutes 10 per kilometre, done")
        #expect(days[3].spoken == "Thursday 29: rest day")
        #expect(days[2].spoken.hasPrefix("Today, Wednesday 28: Intervals: 5 × 600 m"))
    }

    @Test func eachSessionOpensOnItsOwnWithItsDayInItsLabel() throws {
        let days = WeekModel(schedule: try schedule(), week: 3).days
        #expect(days[2].items.first?.id == "00000000-0000-4000-8000-000000000017")
        #expect(days[0].itemsSpoken == ["Monday 26: Easy run, 5 km · 6 minutes 25 to 7 minutes 10 per kilometre, done"])
        #expect(days[6].itemsSpoken == ["Sunday 1: Cycling, 45 min · easy effort, yours"])
    }

    @Test func aSessionIsAddedOnTodayInThisWeekElseTheFirstDay() throws {
        let s = try schedule()
        #expect(WeekModel(schedule: s, week: 3).addDate == "2026-10-28")
        #expect(WeekModel(schedule: s, week: 4).addDate == "2026-11-02")
    }
}
