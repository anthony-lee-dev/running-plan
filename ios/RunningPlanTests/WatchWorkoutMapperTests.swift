import APIClient
import Foundation
import Testing
import WorkoutKit
@testable import RunningPlan

/// The WorkoutKit mapping (task 4.2): our steps to Apple's warm-up, interval blocks and cool-down.
struct WatchWorkoutMapperTests {
    private func content(on date: String) throws -> Components.Schemas.SessionContent {
        try SessionSheetModelTests.session(on: date).value2
    }

    private func pace(_ minSec: Int, _ maxSec: Int) -> SpeedRangeAlert {
        .init(target: Measurement(value: 1000 / Double(maxSec), unit: UnitSpeed.metersPerSecond)...Measurement(value: 1000 / Double(minSec), unit: UnitSpeed.metersPerSecond), metric: .current)
    }

    @Test func intervalsBecomeWarmupARepeatedBlockAndCooldown() throws {
        let workout = try #require(WatchWorkoutMapper.workout(for: try content(on: "2026-10-28")))
        let warmup = WorkoutStep(goal: .distance(1500, .meters), alert: pace(385, 430))
        let block = IntervalBlock(
            steps: [
                IntervalStep(.work, step: WorkoutStep(goal: .distance(600, .meters), alert: pace(315, 330))),
                IntervalStep(.recovery, step: WorkoutStep(goal: .distance(200, .meters), alert: nil)),
            ],
            iterations: 5
        )
        let cooldown = WorkoutStep(goal: .distance(1400, .meters), alert: pace(385, 430))
        let expected = CustomWorkout(activity: .running, location: .outdoor, displayName: "Intervals: 5 × 600 m", warmup: warmup, blocks: [block], cooldown: cooldown)
        #expect(workout == expected)
    }

    @Test func aSingleStepRunIsOneBlockWithItsPaceAlert() throws {
        let workout = try #require(WatchWorkoutMapper.workout(for: try content(on: "2026-10-30")))
        let block = IntervalBlock(steps: [IntervalStep(.work, step: WorkoutStep(goal: .distance(5000, .meters), alert: pace(385, 430)))], iterations: 1)
        let expected = CustomWorkout(activity: .running, location: .outdoor, displayName: "Easy run", warmup: nil, blocks: [block], cooldown: nil)
        #expect(workout == expected)
    }

    @Test func strengthAndCrossTrainingAreNotSentToTheWatch() throws {
        #expect(WatchWorkoutMapper.workout(for: try content(on: "2026-10-27")) == nil)
        #expect(WatchWorkoutMapper.workout(for: try content(on: "2026-11-01")) == nil)
    }

    private func run(_ steps: String, type: String = "tempo") throws -> Components.Schemas.SessionContent {
        let json = #"{"date":"2026-11-02","type":"\#(type)","status":"planned","owner":"system","steps":\#(steps)}"#
        return try JSONDecoder().decode(Components.Schemas.SessionContent.self, from: Data(json.utf8))
    }

    @Test func goalsAndTargetsMapToWatchGoalsAndAlerts() throws {
        let steps = #"[{"kind":"work","goal":{"type":"time","value":600},"target":{"type":"heart_rate","range":{"minBpm":150,"maxBpm":165}}},{"kind":"work","goal":{"type":"open"},"target":{"type":"effort","effort":"hard"}},{"kind":"work","goal":{"type":"time","value":60},"target":{"type":"none"}}]"#
        let workout = try #require(WatchWorkoutMapper.workout(for: try run(steps)))
        let timed = WorkoutStep(goal: .time(600, .seconds), alert: .heartRate(150...165))
        let open = WorkoutStep(goal: .open, alert: nil)
        let bare = WorkoutStep(goal: .time(60, .seconds), alert: nil)
        let blocks: [IntervalBlock] = [timed, open, bare].map { IntervalBlock(steps: [IntervalStep(.work, step: $0)], iterations: 1) }
        #expect(workout.warmup == nil)
        #expect(workout.cooldown == nil)
        #expect(workout.blocks == blocks)
    }

    @Test func aWarmupThatIsNotFirstIsNotTheWatchsWarmup() throws {
        let steps = #"[{"kind":"work","goal":{"type":"time","value":600}},{"kind":"warmup","goal":{"type":"time","value":300}}]"#
        let workout = try #require(WatchWorkoutMapper.workout(for: try run(steps)))
        #expect(workout.warmup == nil)
        #expect(workout.blocks.count == 2)
    }

    @Test func aSessionWithoutRunStepsHasNoWorkout() throws {
        #expect(WatchWorkoutMapper.workout(for: try run("[]")) == nil)
    }

    @Test func aPlanKeepsTheSameIdUntilTheSessionChanges() throws {
        let session = try SessionSheetModelTests.session(on: "2026-10-28")
        let first = try #require(WatchWorkoutMapper.plan(for: session))
        let again = try #require(WatchWorkoutMapper.plan(for: session))
        #expect(first.id == again.id)
        #expect(WatchWorkoutMapper.planID(sessionId: session.value1.id, revision: session.value1.revision + 1) != first.id)
        #expect(WatchWorkoutMapper.planID(sessionId: "other", revision: session.value1.revision) != first.id)
    }

    @Test func aPaceRangeIsFastestEndFirstSoTheSpeedRangeIsTheWayRound() {
        let alert = WatchWorkoutMapper.alert(.pace(.init(_type: .pace, range: .init(minSecPerKm: 300, maxSecPerKm: 360))))
        #expect(alert as? SpeedRangeAlert == pace(300, 360))
    }

    @Test func aBackwardsPaceRangeGivesNoAlertInsteadOfCrashing() {
        #expect(WatchWorkoutMapper.alert(.pace(.init(_type: .pace, range: .init(minSecPerKm: 400, maxSecPerKm: 300)))) == nil)
    }
}
