import APIClient
import Foundation
import HealthKit

/// Reads workouts from Apple Health. Read access is asked for only when the user taps (`requestAccess`); background
/// refreshes run only when `needsAccess` is false, so no system prompt ever appears unasked.
protocol HealthImporting: Sendable {
    var isAvailable: Bool { get }
    /// True while the system has not yet asked the user for read access.
    func needsAccess() async -> Bool
    func requestAccess() async throws
    func workouts(since: Date) async throws -> [HealthWorkout]
}

struct LiveHealthImporter: HealthImporting, @unchecked Sendable {
    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming), HKQuantityType(.heartRate)]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func needsAccess() async -> Bool {
        guard isAvailable else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status != .unnecessary
    }

    func requestAccess() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// The newest 200 workouts since `since`; older ones in a very busy month are not read.
    func workouts(since: Date) async throws -> [HealthWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 200, sortDescriptors: [sort]) { _, results, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: results ?? []) }
            }
            store.execute(query)
        }
        return samples.compactMap { ($0 as? HKWorkout).map(Self.workout) }
    }

    private static func workout(_ w: HKWorkout) -> HealthWorkout {
        let beats = HKUnit.count().unitDivided(by: .minute())
        let heart = w.statistics(for: HKQuantityType(.heartRate))
        let distance = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
            .compactMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }.first
        let zone = (w.metadata?[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
        return HealthWorkout(
            uuid: w.uuid.uuidString,
            type: type(w.workoutActivityType),
            start: w.startDate,
            timeZone: zone,
            durationSec: w.duration,
            distanceM: distance,
            avgHeartRate: heart?.averageQuantity()?.doubleValue(for: beats),
            maxHeartRate: heart?.maximumQuantity()?.doubleValue(for: beats),
            sourceName: w.sourceRevision.source.name,
            productType: w.sourceRevision.productType
        )
    }

    private static func type(_ type: HKWorkoutActivityType) -> Components.Schemas.WorkoutType {
        switch type {
        case .running: .running
        case .traditionalStrengthTraining, .functionalStrengthTraining: .strength
        case .cycling: .cycling
        case .swimming: .swimming
        case .walking: .walking
        default: .other
        }
    }
}
