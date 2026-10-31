import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct PlanScheduleTests {
    private func schedule(today: String = PlanFixture.today) throws -> PlanSchedule {
        PlanSchedule(plan: try PlanFixture.detail(), today: today)
    }

    @Test func theBoardsTodayIsWednesdayOfWeekFour() throws {
        let s = try schedule()
        #expect(s.position == .week(3))
        #expect(s.weekCount == 10)
        #expect(s.phase(ofWeek: 3) == .build)
        #expect(s.todaySessions.map(\.value2.title) == ["Intervals: 5 × 600 m"])
        #expect(s.nextSession?.value2.date == "2026-10-30", "Thursday is a rest day, so next up is Friday's easy run")
    }

    @Test func aWeekIsMondayToSundayFromTheStartDate() throws {
        let s = try schedule()
        #expect(s.weekRange(3) == ("2026-10-26", "2026-11-01"))
        #expect(s.days(ofWeek: 3) == ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"])
        #expect(try schedule(today: "2026-11-01").position == .week(3))
        #expect(try schedule(today: "2026-11-02").position == .week(4))
        #expect(try schedule(today: "2026-10-05").position == .week(0))
    }

    @Test func aRestDayHasNoSessionAndPointsAtTheNext() throws {
        let s = try schedule(today: "2026-10-29")
        #expect(s.todaySessions.isEmpty)
        #expect(s.nextSession?.value2.date == "2026-10-30")
    }

    @Test func beforeTheStartTheFirstSessionIsNext() throws {
        let s = try schedule(today: "2026-10-01")
        #expect(s.position == .notStarted(startsOn: "2026-10-05"))
        #expect(s.todaySessions.isEmpty)
        #expect(s.nextSession?.value2.date == "2026-10-05")
    }

    @Test func raceDayIsTheLastDayAndThenThePlanIsFinished() throws {
        #expect(try schedule(today: "2026-12-13").position == .week(9))
        let after = try schedule(today: "2026-12-14")
        #expect(after.position == .finished)
        #expect(after.nextSession == nil)
    }

    @Test func weekTotalsCountRunningDistanceAndEverySession() throws {
        let s = try schedule()
        #expect(s.sessions(inWeek: 3).map(\.value2.date) == ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-30", "2026-10-31", "2026-11-01"])
        // Strength and the user's cycling count as sessions but not as running distance.
        #expect(s.plannedMetres(week: 3) == 24_900)
        #expect(s.doneCount(week: 3) == 2)
        #expect(s.sessions(inWeek: 3).count == 6)
        #expect(s.plannedMetres(week: 0) == 16_000)
    }
}
