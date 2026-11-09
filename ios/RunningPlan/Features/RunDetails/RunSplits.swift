import Foundation

/// A stretch of distance Health recorded, as seconds from the workout's start. Pure data so the maths is testable
/// without HealthKit.
struct DistanceSample: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let meters: Double
}

/// Per-kilometre splits worked out on the device from the workout's distance samples (splits are never uploaded).
/// Pace uses moving time, so a pause inside a kilometre does not slow it.
enum RunSplits {
    struct Split: Equatable, Identifiable {
        /// 1 for the first kilometre.
        let index: Int
        let distanceM: Double
        let durationSec: Double
        let paceSecPerKm: Int
        /// Speed relative to the fastest full kilometre, 0 to 1: the thin bar behind the row.
        let barFraction: Double
        let isFastest: Bool
        let isSlowest: Bool
        /// The last stretch when it is under a full kilometre.
        let isPartial: Bool
        var id: Int { index }
    }

    /// A last stretch shorter than this is noise, not a split.
    static let shortestPartialM = 100.0

    /// Nothing under one full kilometre: a short run has no splits to show.
    static func make(samples: [DistanceSample]) -> [Split] {
        // Moving-time axis: every usable sample adds its own duration and distance, gaps add nothing.
        let usable = samples
            .filter { $0.meters.isFinite && $0.meters > 0 && $0.end.isFinite && $0.start.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var crossings: [Double] = []   // moving time at which each full kilometre was reached
        var distance = 0.0, moving = 0.0
        for sample in usable {
            let duration = sample.end - sample.start
            var next = Double(crossings.count + 1) * 1000
            while distance + sample.meters >= next - 1e-9 {
                crossings.append(moving + (next - distance) / sample.meters * duration)
                next += 1000
            }
            distance += sample.meters
            moving += duration
        }
        guard let lastCrossing = crossings.last else { return [] }
        var raw: [(distance: Double, duration: Double, partial: Bool)] = []
        for k in crossings.indices { raw.append((1000, crossings[k] - (k == 0 ? 0 : crossings[k - 1]), false)) }
        let leftover = distance - Double(crossings.count) * 1000
        if leftover >= shortestPartialM { raw.append((leftover, moving - lastCrossing, true)) }

        // Whole seconds per km, as shown: two splits that read the same are the same (no fastest or slowest between them).
        let paces = raw.map { ($0.duration / ($0.distance / 1000)).rounded() }
        let full = raw.indices.filter { !raw[$0].partial }.map { paces[$0] }
        let fastest = full.min(), slowest = full.max()
        let mark = full.count >= 2 && fastest != slowest
        return raw.indices.map { i in
            Split(
                index: i + 1, distanceM: raw[i].distance, durationSec: raw[i].duration,
                paceSecPerKm: Int(paces[i].rounded()),
                barFraction: fastest.map { min(1, $0 / paces[i]) } ?? 1,
                isFastest: mark && !raw[i].partial && paces[i] == fastest,
                isSlowest: mark && !raw[i].partial && paces[i] == slowest,
                isPartial: raw[i].partial
            )
        }
    }
}
