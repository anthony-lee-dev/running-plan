import APIClient
import Foundation
import Testing
import WorkoutKit
@testable import RunningPlan

private final class FakeScheduler: WatchScheduling {
    var isSupported = true
    var maxWorkouts = 15
    var state: WatchAuthorization = .authorized
    var asked = 0
    var askAnswer: WatchAuthorization = .authorized
    var items: [WatchItem] = []
    var log: [String] = []

    func authorization() async -> WatchAuthorization { state }
    func requestAuthorization() async -> WatchAuthorization {
        asked += 1
        state = askAnswer
        return state
    }
    func scheduled() async -> [WatchItem] { items }
    func schedule(_ item: WatchItem) async {
        log.append("add \(item.date)")
        items.append(item)
    }
    func remove(_ item: WatchItem) async {
        log.append("remove \(item.date)")
        items.removeAll { $0.key == item.key }
    }
}

struct WatchSyncTests {
    static let sessions = (try? PlanFixture.detail().value2.sessions) ?? []

    private func item(_ n: Int, date: String) -> WatchItem {
        let plan = WorkoutPlan(.goal(SingleGoalWorkout(activity: .running)), id: WatchWorkoutMapper.planID(sessionId: "s\(n)", revision: 1))
        return WatchItem(id: plan.id, date: date, plan: plan)
    }

    @Test func theWindowIsTheUpcomingPlannedRunsOnly() {
        let window = WatchSync.window(sessions: Self.sessions, today: "2026-10-28")
        let dates = window.map(\.date).prefix(3)
        // Wed intervals, Fri easy, Sat long; the Tuesday strength, Thursday rest and Sunday cycling are not runs.
        let expected = ["2026-10-28", "2026-10-30", "2026-10-31"]
        #expect(Array(dates) == expected)
    }

    @Test func theWindowHoldsAtMostFifteenAndSkipsDoneOnes() {
        let window = WatchSync.window(sessions: Self.sessions, today: "2026-10-05")
        #expect(window.count == 15)
        // Weeks 1 to 3 are done, so the first is week 4's Wednesday.
        #expect(window.first?.date == "2026-10-28")
        #expect(WatchSync.window(sessions: Self.sessions, today: "2026-10-05", limit: 4).count == 4)
    }

    @Test func nothingIsInTheWindowAfterThePlanEnds() {
        #expect(WatchSync.window(sessions: Self.sessions, today: "2027-01-01").isEmpty)
    }

    @Test func diffAddsNewRemovesGoneAndLeavesTheSame() {
        let keep = item(1, date: "2026-10-28")
        let gone = item(2, date: "2026-10-29")
        let new = item(3, date: "2026-10-30")
        let changes = WatchSync.diff(desired: [keep, new], existing: [keep, gone])
        #expect(changes.remove.map(\.key) == [gone.key])
        #expect(changes.add.map(\.key) == [new.key])
    }

    @Test func aMovedSessionIsRemovedFromItsOldDayAndAddedOnTheNew() {
        let before = item(1, date: "2026-10-28")
        let after = WatchItem(id: before.id, date: "2026-10-29", plan: before.plan)
        let changes = WatchSync.diff(desired: [after], existing: [before])
        #expect(changes.remove.map(\.date) == ["2026-10-28"])
        #expect(changes.add.map(\.date) == ["2026-10-29"])
    }

    @Test func aFullScheduleThatShiftsByADayStaysAtTheCap() {
        let existing = (0..<15).map { item($0, date: String(format: "2026-11-%02d", $0 + 1)) }
        let desired = (1..<16).map { item($0, date: String(format: "2026-11-%02d", $0 + 1)) }
        let changes = WatchSync.diff(desired: desired, existing: existing)
        #expect(changes.remove.count == 1)
        #expect(changes.add.count == 1)
    }

    @Test func dateComponentsComeFromTheStringWithoutATimeZone() {
        let c = item(1, date: "2026-03-08").components
        #expect(c.year == 2026 && c.month == 3 && c.day == 8)
        #expect(c.hour == nil && c.timeZone == nil)
    }

    // MARK: The model, scenario by scenario (design #100)

    @MainActor private func fresh(_ scheduler: FakeScheduler = FakeScheduler(), defaults: UserDefaults? = nil) throws -> (WatchSyncModel, UserDefaults) {
        let store = try defaults ?? #require(UserDefaults(suiteName: "WatchSyncTests.\(UUID().uuidString)"))
        return (WatchSyncModel(scheduler: scheduler, defaults: store), store)
    }

    private static let loaded: PlanStore.State = {
        guard let detail = try? PlanFixture.detail() else { return .loading }
        return .loaded(detail)
    }()
    private static let today = "2026-10-28"

    @MainActor @Test func turningOnAsksOnceThenSchedulesTheWindow() async throws {
        let scheduler = FakeScheduler()
        scheduler.state = .notDetermined
        let (model, _) = try fresh(scheduler)
        await model.update(state: .loading, account: "a", today: Self.today)
        #expect(model.shouldOfferTurnOn)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        #expect(scheduler.asked == 1)
        #expect(model.status == .synced(15))
        #expect(scheduler.items.count == 15)
        #expect(model.wantsSync)
        #expect(!model.shouldOfferTurnOn)
    }

    @MainActor @Test func notNowAnswersTheCardWithoutTurningOn() async throws {
        let scheduler = FakeScheduler()
        let (model, defaults) = try fresh(scheduler)
        await model.update(state: .loading, account: "a", today: Self.today)
        await model.markAsked()
        #expect(!model.shouldOfferTurnOn)
        #expect(!model.wantsSync)
        #expect(scheduler.asked == 0)
        // Remembered for this account when the app starts again.
        let again = WatchSyncModel(scheduler: scheduler, defaults: defaults)
        await again.update(state: .loading, account: "a", today: Self.today)
        #expect(!again.shouldOfferTurnOn)
    }

    @MainActor @Test func theCardIsNotOfferedWithoutSchedulingSupportOrAnAccount() async throws {
        let scheduler = FakeScheduler()
        scheduler.isSupported = false
        let (unsupported, _) = try fresh(scheduler)
        await unsupported.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(!unsupported.shouldOfferTurnOn)
        #expect(unsupported.status == .unsupported)
        let (signedOut, _) = try fresh()
        await signedOut.update(state: .empty, account: nil, today: Self.today)
        #expect(!signedOut.shouldOfferTurnOn)
    }

    @MainActor @Test func declinedPermissionKeepsTheIntentAndResumesWhenAllowedAgain() async throws {
        let scheduler = FakeScheduler()
        scheduler.state = .notDetermined
        scheduler.askAnswer = .denied
        let (model, _) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        #expect(model.status == .denied)
        #expect(model.wantsSync)
        #expect(scheduler.items.isEmpty)

        // A resync never asks again, and stays denied.
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(scheduler.asked == 1)
        #expect(model.status == .denied)

        scheduler.state = .authorized
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(model.status == .synced(15))
        #expect(scheduler.items.count == 15)
    }

    @MainActor @Test func revokedPermissionShowsAsDeniedAndResumesWhenRestored() async throws {
        let scheduler = FakeScheduler()
        let (model, _) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        scheduler.state = .denied
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(model.status == .denied)
        #expect(model.wantsSync)
        scheduler.state = .authorized
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(model.status == .synced(15))
    }

    @MainActor @Test func resyncNeverAsksAndDoesNothingWhileOff() async throws {
        let scheduler = FakeScheduler()
        scheduler.state = .notDetermined
        let (model, _) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(scheduler.asked == 0)
        #expect(scheduler.items.isEmpty)
        #expect(model.status == .off)
    }

    @MainActor @Test func comingToTheFrontMovesTheWindowAndOnlyChangesWhatMoved() async throws {
        let scheduler = FakeScheduler()
        let (model, _) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        scheduler.log = []
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(scheduler.log.isEmpty)
        // A day passes (the app comes to the front on another date).
        await model.update(state: Self.loaded, account: "a", today: "2026-10-31")
        #expect(scheduler.log.filter { $0.hasPrefix("remove") }.count == 2)
        #expect(scheduler.log.first?.hasPrefix("remove") == true)
        #expect(scheduler.items.count == 15)
    }

    @MainActor @Test func aDeletedOrEmptyPlanClearsTheWatchButKeepsTheSetting() async throws {
        let scheduler = FakeScheduler()
        let (model, _) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        await model.update(state: .empty, account: "a", today: Self.today)
        #expect(scheduler.items.isEmpty)
        #expect(model.wantsSync)
        // The next plan syncs on its own.
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(scheduler.items.count == 15)
    }

    @MainActor @Test func loadingAndErrorsNeverClearTheWatch() async throws {
        let scheduler = FakeScheduler()
        let (model, _) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        scheduler.log = []
        await model.update(state: .loading, account: "a", today: Self.today)
        await model.update(state: .failed("offline"), account: "a", today: Self.today)
        #expect(scheduler.log.isEmpty)
        #expect(scheduler.items.count == 15)
        #expect(model.status == .synced(15))
    }

    @MainActor @Test func signingOutRemovesEverythingAndTheSettingBelongsToTheAccount() async throws {
        let scheduler = FakeScheduler()
        let (model, defaults) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        await model.update(state: .empty, account: nil, today: Self.today)
        #expect(scheduler.items.isEmpty)
        #expect(model.status == .off)
        // Signing back in as the same account finds its setting again.
        let again = WatchSyncModel(scheduler: scheduler, defaults: defaults)
        await again.update(state: Self.loaded, account: "a", today: Self.today)
        #expect(again.wantsSync)
        #expect(scheduler.items.count == 15)
    }

    @MainActor @Test func anotherAccountStartsOffAndDoesNotKeepTheFirstOnesWorkouts() async throws {
        let scheduler = FakeScheduler()
        let (first, defaults) = try fresh(scheduler)
        await first.update(state: Self.loaded, account: "a", today: Self.today)
        await first.turnOn(sessions: Self.sessions, today: Self.today)
        // The app restarts with account b signed in, whose sync is off.
        let second = WatchSyncModel(scheduler: scheduler, defaults: defaults)
        await second.update(state: Self.loaded, account: "b", today: Self.today)
        #expect(scheduler.items.isEmpty)
        #expect(!second.wantsSync)
        #expect(second.status == .off)
        #expect(second.shouldOfferTurnOn)
        #expect(defaults.bool(forKey: "watch.sync.a"))
    }

    @MainActor @Test func turningOffClearsTheSchedule() async throws {
        let scheduler = FakeScheduler()
        let (model, _) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        await model.turnOff()
        #expect(scheduler.items.isEmpty)
        #expect(model.status == .off)
        #expect(!model.wantsSync)
        #expect(!model.shouldOfferTurnOn)
    }

    @MainActor @Test func aDeviceWithoutSchedulingSupportSaysSo() async throws {
        let scheduler = FakeScheduler()
        scheduler.isSupported = false
        let (model, _) = try fresh(scheduler)
        await model.update(state: Self.loaded, account: "a", today: Self.today)
        await model.turnOn(sessions: Self.sessions, today: Self.today)
        #expect(model.status == .unsupported)
        #expect(scheduler.items.isEmpty)
    }

    // MARK: Status copy

    private func run(on date: String) throws -> Components.Schemas.Session {
        try #require(Self.sessions.first { $0.value2.date == date })
    }

    private func line(_ date: String, _ status: WatchSyncModel.Status, today: String = "2026-10-28", limit: Int = 15) throws -> WatchStatusCopy.Line? {
        WatchStatusCopy.line(for: try run(on: date), in: Self.sessions, status: status, limit: limit, today: today)
    }

    @Test func aRunInTheWindowSaysWhereItIs() throws {
        let result = try line("2026-11-04", .synced(15))
        #expect(result?.text == "On your watch: in the Workout app for Wed 4 Nov.")
        #expect(result?.offersSettings == false)
    }

    @Test func aRunBeyondTheWindowSaysItComesCloserToTheDay() throws {
        let result = try line("2026-11-04", .synced(2), limit: 2)
        #expect(result?.text == "Goes to your watch closer to the day.")
    }

    @Test func whenSyncIsOffTheLineSaysHowToTurnItOn() throws {
        #expect(try line("2026-10-30", .off)?.text == "Not on your watch. Turn on in Watch settings.")
    }

    @Test func notAllowedOffersOpenSettings() throws {
        let result = try line("2026-10-30", .denied)
        #expect(result?.text == "Running Plan can't add workouts. Allow it in Settings.")
        #expect(result?.offersSettings == true)
    }

    @Test func noLineWhenUnsupportedOrNotARunOrNotUpcoming() throws {
        #expect(try line("2026-10-30", .unsupported) == nil)
        // Strength and custom sessions never go to the watch.
        #expect(try line("2026-11-10", .synced(15)) == nil)
        #expect(try line("2026-11-01", .synced(15)) == nil)
        // A run already past has nothing to say.
        #expect(try line("2026-10-30", .synced(15), today: "2026-11-02") == nil)
    }

    @Test func theSettingsLineCountsTheRunsAndNamesTheLastDay() {
        #expect(WatchStatusCopy.settingsLine(status: .synced(12), count: 12, through: "2026-11-23").text == "Your next 12 runs are in the Workout app, up to Mon 23 Nov.")
        #expect(WatchStatusCopy.settingsLine(status: .synced(1), count: 1, through: "2026-11-23").text == "Your next run is in the Workout app, on Mon 23 Nov.")
        #expect(WatchStatusCopy.settingsLine(status: .off, count: 0, through: nil).text == "Off. Your runs stay in this app.")
        #expect(WatchStatusCopy.settingsLine(status: .denied, count: 0, through: nil).offersSettings)
        #expect(WatchStatusCopy.settingsLine(status: .unsupported, count: 0, through: nil).text == "Needs an iPhone paired with an Apple Watch.")
    }

    @Test func daysReadWeekdayDayMonth() {
        #expect(WatchStatusCopy.day("2026-11-04") == "Wed 4 Nov")
    }
}
