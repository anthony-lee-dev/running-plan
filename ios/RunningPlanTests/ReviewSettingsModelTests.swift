import APIClient
import Testing
@testable import RunningPlan

private actor FakeSettings: ReviewSettingsServing {
    private(set) var saved: [ReviewSetting] = []
    var current = ReviewSetting(frequency: .weekly_plus_urgent, day: nil, revision: 1)
    var saveError: ReviewError?

    func set(saveError: ReviewError?, current: ReviewSetting? = nil) {
        self.saveError = saveError
        if let current { self.current = current }
    }

    func load() async throws -> ReviewSetting { current }

    func save(_ setting: ReviewSetting) async throws -> ReviewSetting {
        saved.append(setting)
        if let saveError { throw saveError }
        current = ReviewSetting(frequency: setting.frequency, day: setting.day, revision: setting.revision + 1)
        return current
    }
}

@MainActor
struct ReviewSettingsModelTests {
    @Test func theDefaultIsWeeklyPlusUrgentOnTheLastDayOfTheWeek() async {
        let model = ReviewSettingsModel(service: FakeSettings())
        await model.load()
        #expect(model.state == .loaded(ReviewSetting(frequency: .weekly_plus_urgent, day: nil, revision: 1)))
    }

    @Test func choosingAFrequencySendsItWithTheRevisionAndKeepsTheDay() async {
        let service = FakeSettings()
        await service.set(saveError: nil, current: ReviewSetting(frequency: .weekly, day: .sun, revision: 4))
        let model = ReviewSettingsModel(service: service)
        await model.load()

        await model.choose(frequency: .after_import)

        #expect(await service.saved == [ReviewSetting(frequency: .after_import, day: .sun, revision: 4)])
        #expect(model.state == .loaded(ReviewSetting(frequency: .after_import, day: .sun, revision: 5)))
    }

    @Test func choosingTheSameFrequencySendsNothing() async {
        let service = FakeSettings()
        let model = ReviewSettingsModel(service: service)
        await model.load()
        await model.choose(frequency: .weekly_plus_urgent)
        #expect(await service.saved.isEmpty)
    }

    @Test func aDayCanBeChosenAndClearedBackToTheLastDay() async {
        let service = FakeSettings()
        let model = ReviewSettingsModel(service: service)
        await model.load()
        await model.choose(day: .mon)
        await model.choose(day: nil)
        let days = await service.saved.map(\.day)
        let expected: [Components.Schemas.Weekday?] = [.mon, nil]
        #expect(days == expected)
    }

    @Test func aChangeMadeElsewhereReloadsAndSaysSo() async {
        let service = FakeSettings()
        let model = ReviewSettingsModel(service: service)
        await model.load()
        await service.set(saveError: .notPending, current: ReviewSetting(frequency: .off, day: nil, revision: 9))

        await model.choose(frequency: .weekly)

        #expect(model.state == .loaded(ReviewSetting(frequency: .off, day: nil, revision: 9)))
        #expect(model.error?.contains("changed somewhere else") == true)
    }
}
