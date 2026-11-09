import APIClient
import Foundation

/// What the heart-rate zones part of Run details shows. Pure.
enum ZonesSection: Equatable {
    /// Nothing to show and nothing to ask (a run without heart-rate readings, or the user said no thanks).
    case hidden
    /// The run has readings but no maximum yet: ask once.
    case askForMax
    case zones([HeartRateZones.ZoneTime])

    static func make(
        samples: RunSamples?, durationSec: Int, settings: Components.Schemas.HeartRateSettings?, declined: Bool
    ) -> ZonesSection {
        guard let samples, !samples.heart.isEmpty else { return .hidden }
        guard let maxBpm = settings?.maxBpm else { return declined ? .hidden : .askForMax }
        let own = settings?.zones.flatMap { $0.count == 5 ? $0.map { ($0.minBpm, $0.maxBpm) } : nil }
        return HeartRateZones.timeInZones(samples: samples.heart, duration: TimeInterval(durationSec), maxBpm: maxBpm, zones: own).map { .zones($0) } ?? .hidden
    }

    /// The valid range for a typed maximum, the same as the profile's.
    static let maxBpmRange = 100...230
}
