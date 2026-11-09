import APIClient
import Foundation
import Testing
@testable import RunningPlan

private func fields(
    distance: Int? = 5000, duration: Int = 1800, avg: Int? = 150, max: Int? = 172, elevation: Int? = 42,
    type: Components.Schemas.WorkoutType = .running, source: String? = "Apple Watch"
) -> Components.Schemas.ActivityFields {
    .init(
        source: .apple_health, externalId: "x", sourceApp: source, workoutType: type, startedAt: Date(timeIntervalSince1970: 1_792_994_000),
        localDate: "2026-10-28", durationSec: duration, distanceM: distance, avgHeartRate: avg, maxHeartRate: max, elevationGainM: elevation
    )
}

struct RunDetailsModelTests {
    @Test func aFullRunShowsHeroStatsAndEveryGridStat() {
        let model = RunDetailsModel(activity: fields(), session: nil, splitsMissing: false)
        #expect(model.hero.map(\.label) == ["Distance", "Time", "Pace"])
        #expect(model.hero.map(\.value) == ["5.00 km", "30:00", "6:00/km"])
        #expect(model.grid.map(\.label) == ["Avg heart rate", "Max heart rate", "Elevation gain"])
        #expect(model.grid.map(\.value) == ["150 bpm", "172 bpm", "42 m"])
        #expect(model.limitedDataNote == nil)
        #expect(model.planChip == "Not part of a plan")
    }

    @Test func missingStatsAreHiddenNeverZeroOrDashAndANoteSaysWhy() {
        let model = RunDetailsModel(activity: fields(avg: nil, max: nil, elevation: nil, source: "Garmin Connect"), session: nil, splitsMissing: false)
        #expect(model.grid.isEmpty)
        #expect(model.limitedDataNote == "Limited data from Garmin Connect: the stats it didn't record are left out.")
        let all = model.hero + model.grid
        #expect(!all.contains { $0.value.contains("—") || $0.value.hasPrefix("0 ") })
    }

    @Test func noDistanceHidesDistanceAndPace() {
        let model = RunDetailsModel(activity: fields(distance: nil), session: nil, splitsMissing: false)
        #expect(model.hero.map(\.label) == ["Time"])
    }

    @Test func missingSplitsAloneTriggerTheNote() {
        let model = RunDetailsModel(activity: fields(), session: nil, splitsMissing: true)
        #expect(model.limitedDataNote != nil)
    }

    @Test func aMatchedRunWhoseSessionIsGoneSaysSo() {
        let model = RunDetailsModel(activity: fields(), session: nil, splitsMissing: false, matchedSessionMissing: true)
        #expect(model.planChip == "Matched to a session no longer in your plan")
    }

    @Test func aMatchedSessionGivesAChipAndPlanVsActual()throws {
        let session = try CheckInModelTests.session(on: "2026-10-26")
        let model = RunDetailsModel(activity: fields(), session: session, splitsMissing: false)
        #expect(model.planChip.hasPrefix("Matched · "))
        #expect(model.planVsActual?.distance?.actual == "5.0 km")
    }
}
