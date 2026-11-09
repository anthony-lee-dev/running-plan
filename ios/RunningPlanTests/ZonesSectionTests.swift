import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct ZonesSectionTests {
    private let samples = RunSamples(distance: [], heart: [HeartSample(offset: 0, bpm: 150), HeartSample(offset: 10, bpm: 160)])

    @Test func aRunWithoutHeartReadingsShowsNoZonesAndNoQuestion() {
        #expect(ZonesSection.make(samples: RunSamples(), durationSec: 600, settings: nil, declined: false) == .hidden)
        #expect(ZonesSection.make(samples: nil, durationSec: 600, settings: .init(maxBpm: 190), declined: false) == .hidden)
    }

    @Test func withReadingsAndNoMaximumTheScreenAsksOnceThenStopsAsking() {
        #expect(ZonesSection.make(samples: samples, durationSec: 600, settings: .init(), declined: false) == .askForMax)
        #expect(ZonesSection.make(samples: samples, durationSec: 600, settings: .init(), declined: true) == .hidden)
    }

    @Test func aSavedMaximumGivesZonesEvenAfterAnEarlierNoThanks() {
        let result = ZonesSection.make(samples: samples, durationSec: 20, settings: .init(maxBpm: 190), declined: true)
        if case .zones(let zones) = result {
            #expect(zones.count == 5)
        } else {
            Issue.record("expected zones")
        }
    }
}
