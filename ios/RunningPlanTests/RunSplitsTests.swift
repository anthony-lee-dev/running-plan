import Foundation
import Testing
@testable import RunningPlan

/// Distance samples as Health stores them: offsets in seconds from the workout's start, metres in each.
private func steady(km: Double, paceSecPerKm: Double, chunkSec: Double = 5) -> [DistanceSample] {
    let total = km * paceSecPerKm
    var samples: [DistanceSample] = []
    var t = 0.0
    while t < total - 0.001 {
        let end = min(t + chunkSec, total)
        samples.append(DistanceSample(start: t, end: end, meters: (end - t) / paceSecPerKm * 1000))
        t = end
    }
    return samples
}

private extension DistanceSample {
    func shifted(by seconds: Double) -> DistanceSample { DistanceSample(start: start + seconds, end: end + seconds, meters: meters) }
}

struct RunSplitsTests {
    @Test func steadyFiveKmGivesFiveEvenSplitsWithNoneMarkedExtreme() {
        let splits = RunSplits.make(samples: steady(km: 5, paceSecPerKm: 360))
        #expect(splits.count == 5)
        #expect(splits.allSatisfy { $0.paceSecPerKm == 360 && !$0.isPartial })
        #expect(splits.allSatisfy { !$0.isFastest && !$0.isSlowest })
        #expect(splits.allSatisfy { abs($0.barFraction - 1) < 0.001 })
    }

    @Test func fastestAndSlowestKmAreMarkedAndBarsFollowSpeed() {
        let samples = steady(km: 1, paceSecPerKm: 400)
            + steady(km: 1, paceSecPerKm: 300).map { $0.shifted(by: 400) }
            + steady(km: 1, paceSecPerKm: 350).map { $0.shifted(by: 700) }
        let splits = RunSplits.make(samples: samples)
        #expect(splits.map(\.paceSecPerKm) == [400, 300, 350])
        #expect(splits.map(\.isFastest) == [false, true, false])
        #expect(splits.map(\.isSlowest) == [true, false, false])
        #expect(abs(splits[0].barFraction - 0.75) < 0.01)
        #expect(splits[1].barFraction == 1)
    }

    @Test func aPartialLastKmIsShownButNeverMarked() {
        let splits = RunSplits.make(samples: steady(km: 2.4, paceSecPerKm: 330))
        #expect(splits.count == 3)
        #expect(splits[2].isPartial)
        #expect(abs(splits[2].distanceM - 400) < 1)
        #expect(splits[2].paceSecPerKm == 330)
        #expect(!splits[2].isFastest && !splits[2].isSlowest)
    }

    @Test func aSliverUnderOneHundredMetresIsDropped() {
        #expect(RunSplits.make(samples: steady(km: 2.05, paceSecPerKm: 330)).count == 2)
    }

    @Test func aPauseDoesNotSlowTheKmItFallsIn() {
        // 600 s of standing still between two samples must not count: splits use moving time.
        let samples = steady(km: 1, paceSecPerKm: 360) + steady(km: 1, paceSecPerKm: 360).map { $0.shifted(by: 360 + 600) }
        #expect(RunSplits.make(samples: samples).map(\.paceSecPerKm) == [360, 360])
    }

    @Test func nothingUnderOneKmAndNoSamplesGiveNoSplits() {
        #expect(RunSplits.make(samples: []).isEmpty)
        #expect(RunSplits.make(samples: steady(km: 0.6, paceSecPerKm: 360)).isEmpty)
    }

    @Test func garbageSamplesAreIgnored() {
        let bad = [
            DistanceSample(start: 10, end: 10, meters: 50), DistanceSample(start: 20, end: 15, meters: 50),
            DistanceSample(start: 0, end: 5, meters: -3), DistanceSample(start: 0, end: 5, meters: .nan),
        ]
        #expect(RunSplits.make(samples: bad + steady(km: 1, paceSecPerKm: 360).map { $0.shifted(by: 100) }).count == 1)
    }

    @Test func twoKmWithEqualPacesMarkNothing() {
        let splits = RunSplits.make(samples: steady(km: 1.5, paceSecPerKm: 360))
        #expect(splits.count == 2)
        #expect(splits.allSatisfy { !$0.isFastest && !$0.isSlowest })
    }
}
