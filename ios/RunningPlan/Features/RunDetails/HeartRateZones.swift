import Foundation

/// One heart-rate reading, as seconds from the workout's start.
struct HeartSample: Equatable, Sendable {
    let offset: TimeInterval
    let bpm: Double
}

/// Time in each of five zones, worked out on the device. The maximum is the one the user typed (never inferred, design
/// §6.3). With no zones of their own the bands are 60, 70, 80 and 90 percent of it: starting values for the coach
/// review (H.1).
enum HeartRateZones {
    struct ZoneTime: Equatable, Identifiable {
        /// 1 to 5.
        let zone: Int
        /// The zone starts here (the first zone starts at 0, so a low reading still counts).
        let lowerBpm: Int
        let seconds: Double
        /// Of the time with a reading, 0 to 1.
        let share: Double
        var id: Int { zone }
    }

    static let bandStarts = [0.0, 0.6, 0.7, 0.8, 0.9]
    /// A reading stands for at most this long, so a gap (a pause, a dropped sensor) is not counted as time in a zone.
    static let longestHold = 30.0

    /// `zones` are the user's own five ranges (min and max bpm), or nil for the percentage bands.
    static func timeInZones(samples: [HeartSample], duration: TimeInterval, maxBpm: Int, zones: [(Int, Int)]?) -> [ZoneTime]? {
        guard maxBpm > 0 else { return nil }
        let starts: [Int] = zones.map { $0.enumerated().map { $0.offset == 0 ? 0 : $0.element.0 } }
            ?? bandStarts.map { Int(($0 * Double(maxBpm)).rounded()) }
        guard starts.count == 5 else { return nil }
        let sorted = samples.filter { $0.bpm.isFinite && $0.bpm > 0 && $0.offset.isFinite }.sorted { $0.offset < $1.offset }
        guard !sorted.isEmpty else { return nil }
        var seconds = [Double](repeating: 0, count: 5)
        for (i, sample) in sorted.enumerated() {
            let until = i + 1 < sorted.count ? sorted[i + 1].offset : max(duration, sample.offset)
            let hold = min(max(until - sample.offset, 0), longestHold)
            let zone = starts.lastIndex { Double($0) <= sample.bpm } ?? 0
            seconds[zone] += hold
        }
        let total = seconds.reduce(0, +)
        guard total > 0 else { return nil }
        return (0..<5).map { ZoneTime(zone: $0 + 1, lowerBpm: starts[$0], seconds: seconds[$0], share: seconds[$0] / total) }
    }
}
