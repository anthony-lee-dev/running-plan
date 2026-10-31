import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// DK-Session: the spec sheet for the boards' Wednesday intervals, strength and the user's cycling.
struct SessionSheetModelTests {
    static func schedule() throws -> PlanSchedule {
        PlanSchedule(plan: try PlanFixture.detail(), today: PlanFixture.today)
    }

    static func session(on date: String) throws -> Components.Schemas.Session {
        try #require(try schedule().sessions.first { $0.value2.date == date })
    }

    private func model(on date: String) throws -> SessionSheetModel {
        SessionSheetModel(schedule: try Self.schedule(), session: try Self.session(on: date))
    }

    @Test func theHeaderNamesTheDayTheWeekAndTheTotals() throws {
        let m = try model(on: "2026-10-28")
        #expect(m.eyebrow == "Wednesday, Oct 28 · Week 4")
        #expect(m.title == "Intervals: 5 × 600 m")
        #expect(m.time == "~43 min")
        #expect(m.distance == "~6.9 km")
        #expect(m.effort == "Hard but controlled")
        #expect(m.backLabel == "Today")
        #expect(!m.isYours)
    }

    @Test func stepsAreInWatchBuilderOrderWithTheRepeatGrouped() throws {
        let m = try model(on: "2026-10-28")
        let expected: [SessionSheetModel.Row] = [
            .step(.init(number: 1, title: "Warm-up", target: "Easy effort · 6:25–7:10/km", value: "1.5 km", intensity: .easy)),
            .repeatGroup(count: 5, steps: [
                .init(number: 2, title: "Fast", target: "Pace 5:15–5:30/km", value: "600 m", intensity: .hard),
                .init(number: 3, title: "Easy jog", target: "Recover, no pace target", value: "200 m", intensity: .recovery),
            ]),
            .step(.init(number: 4, title: "Cool-down", target: "Easy effort · 6:25–7:10/km", value: "1.4 km", intensity: .easy)),
        ]
        #expect(m.rows == expected)
        #expect(m.exercises.isEmpty)
    }

    @Test func goalsReadAsAWatchShowsThem() {
        #expect(StepFormat.goal(.init(_type: .time, value: 600)) == "10:00")
        #expect(StepFormat.goal(.init(_type: .time, value: 125)) == "2:05")
        #expect(StepFormat.goal(.init(_type: .time, value: 3725)) == "1:02:05")
        #expect(StepFormat.goal(.init(_type: .distance, value: 600)) == "600 m")
        #expect(StepFormat.goal(.init(_type: .distance, value: 5000)) == "5 km")
        #expect(StepFormat.goal(.init(_type: .distance, value: 1250)) == "1.25 km")
        #expect(StepFormat.goal(.init(_type: .open)) == "Open")
    }

    @Test func strengthIsAnExerciseChecklist() throws {
        let m = try model(on: "2026-10-27")
        #expect(m.rows.isEmpty)
        let expected: [SessionSheetModel.Exercise] = [.init(name: "Goblet squat", detail: "4 × 5:00")]
        #expect(m.exercises == expected)
        #expect(SessionSheetModel.exerciseDetail(.init(kind: .exercise, exerciseId: "plank", sets: 3, durationSec: 30, restSec: 45)) == "3 × 0:30 · rest 0:45")
        #expect(SessionSheetModel.exerciseDetail(.init(kind: .exercise, exerciseId: "glute-bridge", sets: 2, reps: 12, effort: .easy, loadNote: "light")) == "2 × 12 · easy · light")
        #expect(ExerciseLibrary.name("goblet-squat") == "Goblet squat")
        #expect(ExerciseLibrary.name("made-up") == "made-up")
    }

    @Test func aCustomSessionShowsItsActivityAndIsYours() throws {
        let m = try model(on: "2026-11-01")
        #expect(m.isYours)
        #expect(m.time == "~45 min")
        #expect(m.distance == nil)
        let expected: [SessionSheetModel.Row] = [.step(.init(number: 1, title: "Cycling", target: "Easy effort", value: "45:00", intensity: .easy))]
        #expect(m.rows == expected)
    }

    @Test func copyAsTextListsTheStepsForAnotherWatch() throws {
        let text = try model(on: "2026-10-28").text
        let expected = """
        Intervals: 5 × 600 m
        Wednesday, Oct 28 · Week 4

        1. Warm-up: 1.5 km, easy effort · 6:25–7:10/km
        Repeat 5×:
          2. Fast: 600 m, pace 5:15–5:30/km
          3. Easy jog: 200 m, recover, no pace target
        4. Cool-down: 1.4 km, easy effort · 6:25–7:10/km
        """
        #expect(text == expected)
        let strength = try model(on: "2026-10-27").text
        #expect(strength.hasSuffix("☐ Goblet squat: 4 × 5:00"))
    }

    @Test func anotherDayGoesBackToTheWeek() throws {
        #expect(try model(on: "2026-10-30").backLabel == "Week")
    }
}
