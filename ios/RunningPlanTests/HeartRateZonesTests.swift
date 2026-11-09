import Foundation
import Testing
@testable import RunningPlan

struct HeartRateZonesTests {
    // 190 bpm max: bands start at 0, 114, 133, 152 and 171.
    @Test func percentageBandsFollowTheMaxHeartRate() {
        let samples = [HeartSample(offset: 0, bpm: 100), HeartSample(offset: 10, bpm: 120), HeartSample(offset: 20, bpm: 140), HeartSample(offset: 30, bpm: 160), HeartSample(offset: 40, bpm: 180)]
        let result = HeartRateZones.timeInZones(samples: samples, duration: 50, maxBpm: 190, zones: nil)
        #expect(result?.map(\.seconds) == [10, 10, 10, 10, 10])
        #expect(result?.map(\.lowerBpm) == [0, 114, 133, 152, 171])
        #expect(result?.map { $0.share } == [0.2, 0.2, 0.2, 0.2, 0.2])
    }

    @Test func theUsersOwnZonesReplaceTheBands() {
        let zones = [(100, 120), (121, 140), (141, 155), (156, 170), (171, 190)]
        let samples = [HeartSample(offset: 0, bpm: 90), HeartSample(offset: 10, bpm: 150)]
        let result = HeartRateZones.timeInZones(samples: samples, duration: 20, maxBpm: 190, zones: zones)
        #expect(result?[0].seconds == 10)
        #expect(result?[2].seconds == 10)
    }

    @Test func aLongGapBetweenSamplesIsCappedNotCounted() {
        let samples = [HeartSample(offset: 0, bpm: 150), HeartSample(offset: 600, bpm: 150)]
        let result = HeartRateZones.timeInZones(samples: samples, duration: 610, maxBpm: 190, zones: nil)
        #expect(result?.map(\.seconds).reduce(0, +) == HeartRateZones.longestHold + 10)
    }

    @Test func noSamplesOrNoMaxGiveNothing() {
        #expect(HeartRateZones.timeInZones(samples: [], duration: 60, maxBpm: 190, zones: nil) == nil)
        #expect(HeartRateZones.timeInZones(samples: [HeartSample(offset: 0, bpm: 150)], duration: 60, maxBpm: 0, zones: nil) == nil)
    }
}
