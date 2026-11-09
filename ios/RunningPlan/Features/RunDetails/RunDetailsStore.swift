import APIClient
import Foundation
import Observation

/// Loads what Run details needs beyond the stored run: the Health readings (splits, zones), the backfill and the
/// maximum heart rate. All of it is best effort; the stored summary shows at once.
@MainActor
@Observable
final class RunDetailsStore {
    private(set) var splits: [RunSplits.Split] = []
    private(set) var samplesLoaded = false
    /// True from the start until Health has been read, so the splits show a skeleton; only for a run that can have readings.
    private(set) var loading: Bool
    private(set) var weather: RunWeather?
    private(set) var zones: ZonesSection = .hidden
    private(set) var error: String?
    private(set) var saving = false

    private let inbox: InboxStore
    private let heart: MaxHeartRateServing?
    private let defaults: UserDefaults
    private var settings: Components.Schemas.HeartRateSettings?
    private var samples: RunSamples?
    private static let declinedKey = "rundetails.maxhr.declined"

    /// A run read from Health on a device with Health: the only kind that has splits to wait for.
    static func expectsSamples(_ activity: Components.Schemas.Activity, healthAvailable: Bool) -> Bool {
        healthAvailable && activity.value1.source == .apple_health && activity.value1.workoutType == .running
    }

    init(inbox: InboxStore, heart: MaxHeartRateServing?, expectsSamples: Bool, defaults: UserDefaults = .standard) {
        loading = expectsSamples
        self.inbox = inbox
        self.heart = heart
        self.defaults = defaults
    }

    /// True when the run has Health readings and splits could not be made from them (a short run, or a source that
    /// writes no distance samples): the model counts it towards the limited-data note.
    var splitsMissing: Bool { samplesLoaded && splits.isEmpty }

    func open(activityId: String) async {
        defer { loading = false }
        await inbox.backfill(activityId: activityId)
        guard let activity = inbox.allRuns.first(where: { $0.value2.id == activityId }) else { return }
        async let read = inbox.samples(for: activity)
        async let profile = loadSettings()
        samples = await read
        settings = await profile
        samplesLoaded = samples != nil
        weather = samples?.weather
        splits = RunSplits.make(samples: samples?.distance ?? [])
        refreshZones(durationSec: activity.value1.durationSec)
    }

    func saveMax(_ bpm: Int, durationSec: Int) async {
        guard ZonesSection.maxBpmRange.contains(bpm), let heart else { error = "Enter a number from 100 to 230."; return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await heart.save(maxBpm: bpm)
            settings = try await heart.load()
            refreshZones(durationSec: durationSec)
        } catch {
            self.error = "We couldn't save that. Check your connection and try again."
        }
    }

    /// "Not now" is remembered on this device so the question is never asked again; Goal and settings can still hold the value.
    func decline(durationSec: Int) {
        defaults.set(true, forKey: Self.declinedKey)
        refreshZones(durationSec: durationSec)
    }

    private func refreshZones(durationSec: Int) {
        zones = ZonesSection.make(samples: samples, durationSec: durationSec, settings: settings, declined: defaults.bool(forKey: Self.declinedKey))
    }

    private func loadSettings() async -> Components.Schemas.HeartRateSettings? {
        guard let heart else { return nil }
        return try? await heart.load()
    }
}
