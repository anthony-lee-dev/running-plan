import APIClient
import CryptoKit
import Foundation
import WorkoutKit

/// Our session steps as a WorkoutKit custom workout (design §8.4). Pure: no scheduler, no I/O.
///
/// - A leading `warmup` step is the watch's warm-up and a trailing `cooldown` its cool-down.
/// - Every other step is an interval block of its own (one iteration); a repeat group is one block with `count` iterations.
/// - Pace targets become speed-range alerts, heart-rate targets heart-rate alerts; effort and no target give no alert.
/// - Strength, rest and custom (cross-training) sessions are not sent: WorkoutKit would need another activity for them.
enum WatchWorkoutMapper {
    static func workout(for content: Components.Schemas.SessionContent) -> CustomWorkout? {
        switch content._type {
        case .easy, .long, .tempo, .intervals: break
        case .rest, .strength, .custom: return nil
        }
        var steps = content.steps ?? []
        var warmup: WorkoutStep?
        var cooldown: WorkoutStep?
        if case .warmup(let run)? = steps.first {
            warmup = step(run)
            steps.removeFirst()
        }
        if case .cooldown(let run)? = steps.last {
            cooldown = step(run)
            steps.removeLast()
        }
        var blocks: [IntervalBlock] = []
        for item in steps {
            switch item {
            case .warmup(let run), .work(let run), .cooldown(let run):
                blocks.append(IntervalBlock(steps: [IntervalStep(.work, step: step(run))], iterations: 1))
            case .recovery(let run):
                blocks.append(IntervalBlock(steps: [IntervalStep(.recovery, step: step(run))], iterations: 1))
            case ._repeat(let group):
                let inner = group.steps.map { IntervalStep($0.kind == .recovery ? .recovery : .work, step: step($0)) }
                blocks.append(IntervalBlock(steps: inner, iterations: group.count))
            case .exercise: continue
            }
        }
        guard warmup != nil || cooldown != nil || !blocks.isEmpty else { return nil }
        return CustomWorkout(activity: .running, location: .outdoor, displayName: content.title, warmup: warmup, blocks: blocks, cooldown: cooldown)
    }

    /// The plan to preview or schedule. Its id is fixed by the session id and revision, so the same session always
    /// gives the same plan and an edit gives a new one.
    static func plan(for session: Components.Schemas.Session) -> WorkoutPlan? {
        guard let workout = workout(for: session.value2) else { return nil }
        return WorkoutPlan(.custom(workout), id: planID(sessionId: session.value1.id, revision: session.value1.revision))
    }

    static func planID(sessionId: String, revision: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(sessionId)#\(revision)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func step(_ run: Components.Schemas.RunStep) -> WorkoutStep {
        WorkoutStep(goal: goal(run.goal), alert: alert(run.target))
    }

    static func goal(_ goal: Components.Schemas.StepGoal) -> WorkoutGoal {
        switch (goal._type, goal.value) {
        case (.time, let value?): .time(Double(value), .seconds)
        case (.distance, let value?): .distance(Double(value), .meters)
        default: .open
        }
    }

    /// Pace is seconds per km with the faster end first, so the speed range is the other way round.
    static func alert(_ target: Components.Schemas.StepTarget?) -> (any WorkoutAlert)? {
        switch target {
        case .pace(let p)?:
            let fast = p.range.minSecPerKm
            let slow = p.range.maxSecPerKm
            guard fast > 0, fast <= slow else { return nil }
            let low = Measurement(value: 1000 / Double(slow), unit: UnitSpeed.metersPerSecond)
            let high = Measurement(value: 1000 / Double(fast), unit: UnitSpeed.metersPerSecond)
            return SpeedRangeAlert(target: low...high, metric: .current)
        case .heart_rate(let hr)?:
            guard hr.range.minBpm <= hr.range.maxBpm else { return nil }
            return HeartRateRangeAlert.heartRate(Double(hr.range.minBpm)...Double(hr.range.maxBpm))
        default:
            return nil
        }
    }
}
