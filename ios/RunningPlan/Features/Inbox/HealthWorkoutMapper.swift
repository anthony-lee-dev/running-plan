import APIClient
import Foundation

/// A workout read from Health, reduced to what the app uploads. Pure data so the mapping is testable without HealthKit.
struct HealthWorkout: Equatable {
    let uuid: String
    let type: Components.Schemas.WorkoutType
    let start: Date
    /// The zone the workout was recorded in (Health keeps it in the metadata), else the device's.
    let timeZone: TimeZone
    let durationSec: Double
    let distanceM: Double?
    let avgHeartRate: Double?
    let maxHeartRate: Double?
    let sourceName: String
    let productType: String?
}

/// Health workouts to upload records, and manual entries. The API refuses a whole batch when one field is out of
/// range, so a bad optional field is dropped and a record with a bad required one is skipped.
enum HealthWorkoutMapper {
    static let batchSize = 200

    /// "Apple Watch" for Apple's own watches, else the name of the app that wrote the record (Garmin Connect, Nike Run Club).
    static func sourceLabel(sourceName: String, productType: String?) -> String {
        if let productType, productType.hasPrefix("Watch") { return "Apple Watch" }
        return String(sourceName.prefix(64))
    }

    static func input(_ w: HealthWorkout) -> Components.Schemas.ActivityInput? {
        let duration = Int(w.durationSec.rounded())
        guard (1...86_400).contains(duration), !w.uuid.isEmpty, w.uuid.count <= 128 else { return nil }
        func within(_ value: Double?, _ range: ClosedRange<Int>) -> Int? {
            guard let value, value.isFinite else { return nil }
            let rounded = Int(value.rounded())
            return range.contains(rounded) ? rounded : nil
        }
        return .init(value1: .init(
            source: .apple_health,
            externalId: w.uuid,
            sourceApp: sourceLabel(sourceName: w.sourceName, productType: w.productType),
            workoutType: w.type,
            startedAt: w.start,
            localDate: LocalDay.string(from: w.start, in: w.timeZone),
            durationSec: duration,
            distanceM: within(w.distanceM, 0...400_000),
            avgHeartRate: within(w.avgHeartRate, 30...250),
            maxHeartRate: within(w.maxHeartRate, 30...250)
        ))
    }

    /// Batches of at most 200, the API's limit, skipping records that cannot be sent.
    static func batches(_ workouts: [HealthWorkout]) -> [[Components.Schemas.ActivityInput]] {
        let inputs = workouts.compactMap(input)
        return stride(from: 0, to: inputs.count, by: batchSize).map { Array(inputs[$0..<min($0 + batchSize, inputs.count)]) }
    }

    /// A run typed in by hand. `id` is made once per entry sheet and reused on a retry so it is stored once.
    /// Nil when the date is in the future or the distance or time is out of range.
    static func manualRun(id: String, localDate: String, distanceKm: Double, minutes: Double, now: Date, zone: TimeZone) -> Components.Schemas.ActivityInput? {
        let seconds = Int((minutes * 60).rounded())
        let metres = Int((distanceKm * 1000).rounded())
        guard (1...86_400).contains(seconds), (0...400_000).contains(metres), distanceKm.isFinite else { return nil }
        guard localDate <= LocalDay.string(from: now, in: zone) else { return nil }
        return .init(value1: .init(
            source: .manual,
            externalId: id,
            sourceApp: "Added by hand",
            workoutType: .running,
            startedAt: min(LocalDay.noon(of: localDate, in: zone), now),
            localDate: localDate,
            durationSec: seconds,
            distanceM: metres > 0 ? metres : nil
        ))
    }
}
