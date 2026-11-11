import Foundation
import HealthKit

/// One running workout as Health holds it (issue #164, slice 0): counts only, no dates, places or ids.
struct HealthProbeRun: Equatable, Sendable {
    var source: String
    var device: String?
    var durationMin: Int
    var distanceKm: Double?
    var distanceSamples: Int
    var heartSamples: Int
    var medianHeartGapSec: Int?
    /// Workout event type name to count (lap, segment, marker, pause, resume...).
    var eventCounts: [String: Int]
    /// Durations of lap and segment events, seconds, at most 12.
    var lapDurationsSec: [Int]
    /// `workoutActivities` (iOS 16): more than one means a multi-step workout.
    var activities: Int
    var metadataKeys: [String]
}

/// The text the human pastes into issue #164. Pure, so it is unit-tested.
enum HealthProbeReport {
    static func text(runs: [HealthProbeRun]) -> String {
        guard !runs.isEmpty else { return "No running workouts in Health for the last 60 days (or read access is off)." }
        var lines = ["Health probe: \(runs.count) running workouts, newest first"]
        let sources = Dictionary(grouping: runs, by: \.source).sorted { $0.key < $1.key }
        for (source, group) in sources {
            lines.append("")
            lines.append("\(source): \(group.count) \(group.count == 1 ? "run" : "runs")")
            for (index, run) in group.enumerated() {
                lines.append("  \(index + 1). \(describe(run))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ run: HealthProbeRun) -> String {
        var parts = ["\(run.durationMin) min"]
        if let km = run.distanceKm { parts.append(String(format: "%.1f km", km)) } else { parts.append("no total distance") }
        parts.append(run.distanceSamples == 0 ? "no distance samples" : "distance samples \(run.distanceSamples)")
        if run.heartSamples == 0 {
            parts.append("no heart samples")
        } else if let gap = run.medianHeartGapSec {
            parts.append("heart samples \(run.heartSamples), median gap \(gap) s")
        } else {
            parts.append("heart samples \(run.heartSamples)")
        }
        let events = run.eventCounts.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }
        parts.append(events.isEmpty ? "no events" : "events " + events.joined(separator: ", "))
        if !run.lapDurationsSec.isEmpty { parts.append("lap/segment seconds " + run.lapDurationsSec.map(String.init).joined(separator: ",")) }
        parts.append("activities \(run.activities)")
        if let device = run.device { parts.append("device \(device)") }
        parts.append("metadata " + (run.metadataKeys.isEmpty ? "none" : run.metadataKeys.joined(separator: ",")))
        return parts.joined(separator: "; ")
    }
}

/// Reads only what the app already has permission for (workouts, distance, heart rate). The route is not read: that is a
/// new read type, which would ask every existing user again.
struct LiveHealthProbe: Sendable {
    func runs(days: Int = 60, limit: Int = 12) async throws -> [HealthProbeRun] {
        let store = HKHealthStore()
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let running = HKQuery.predicateForWorkouts(with: .running)
        let dated = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [running, dated])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let workouts: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            store.execute(HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, results, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: results ?? []) }
            })
        }
        var out: [HealthProbeRun] = []
        for case let workout as HKWorkout in workouts {
            let inWorkout = HKQuery.predicateForObjects(from: workout)
            let distance = try await samples(store, HKQuantityType(.distanceWalkingRunning), inWorkout)
            let heart = try await samples(store, HKQuantityType(.heartRate), inWorkout)
            var counts: [String: Int] = [:]
            var laps: [Int] = []
            for event in workout.workoutEvents ?? [] {
                counts[Self.name(event.type), default: 0] += 1
                if (event.type == .lap || event.type == .segment), laps.count < 12 { laps.append(Int(event.dateInterval.duration.rounded())) }
            }
            let gaps = zip(heart, heart.dropFirst()).map { $1.startDate.timeIntervalSince($0.startDate) }.sorted()
            out.append(HealthProbeRun(
                source: workout.sourceRevision.source.name,
                device: workout.device?.model,
                durationMin: Int((workout.duration / 60).rounded()),
                distanceKm: workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity().map { $0.doubleValue(for: .meter()) / 1000 },
                distanceSamples: distance.count,
                heartSamples: heart.count,
                medianHeartGapSec: gaps.isEmpty ? nil : Int(gaps[gaps.count / 2].rounded()),
                eventCounts: counts,
                lapDurationsSec: laps,
                activities: workout.workoutActivities.count,
                metadataKeys: (workout.metadata?.keys.sorted() ?? [])
            ))
        }
        return out
    }

    private func samples(_ store: HKHealthStore, _ type: HKQuantityType, _ predicate: NSPredicate) async throws -> [HKQuantitySample] {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let found: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: results ?? []) }
            })
        }
        return found.compactMap { $0 as? HKQuantitySample }
    }

    private static func name(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: "pause"
        case .resume: "resume"
        case .lap: "lap"
        case .segment: "segment"
        case .marker: "marker"
        case .motionPaused: "motionPaused"
        case .motionResumed: "motionResumed"
        case .pauseOrResumeRequest: "pauseOrResumeRequest"
        @unknown default: "other"
        }
    }
}
