import Testing
@testable import RunningPlan

struct HealthProbeReportTests {
    private func run(source: String, distanceSamples: Int = 0, heartSamples: Int = 0, events: [String: Int] = [:], activities: Int = 0) -> HealthProbeRun {
        HealthProbeRun(source: source, device: nil, durationMin: 45, distanceKm: 8.1, distanceSamples: distanceSamples, heartSamples: heartSamples,
                       medianHeartGapSec: heartSamples > 1 ? 5 : nil, eventCounts: events, lapDurationsSec: [], activities: activities, metadataKeys: ["HKTimeZone"])
    }

    @Test func groupsBySourceAndSaysWhatIsMissing() {
        let text = HealthProbeReport.text(runs: [
            run(source: "Garmin Connect"),
            run(source: "Apple Watch", distanceSamples: 480, heartSamples: 540, events: ["lap": 8], activities: 1),
            run(source: "Garmin Connect", heartSamples: 12),
        ])
        #expect(text.contains("Garmin Connect: 2 runs"))
        #expect(text.contains("Apple Watch: 1 run"))
        #expect(text.contains("no distance samples"))
        #expect(text.contains("lap x8"))
        #expect(text.contains("heart samples 540, median gap 5 s"))
    }

    @Test func emptyHealthSaysSo() {
        #expect(HealthProbeReport.text(runs: []).contains("No running workouts"))
    }

    @Test func nothingPersonalIsInTheReport() {
        let text = HealthProbeReport.text(runs: [run(source: "Garmin Connect")])
        #expect(!text.contains("2026"))
        #expect(!text.contains("@"))
    }
}
