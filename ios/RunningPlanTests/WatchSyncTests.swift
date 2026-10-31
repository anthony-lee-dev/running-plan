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
    var items: [WatchItem] = []
    var log: [String] = []

    func authorization() async -> WatchAuthorization { state }
    func requestAuthorization() async -> WatchAuthorization {
        asked += 1
        state = .authorized
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

    @MainActor @Test func turningOnAsksOnceThenSchedulesTheWindow() async throws {
        let scheduler = FakeScheduler()
        scheduler.state = .notDetermined
        let defaults = try #require(UserDefaults(suiteName: "WatchSyncTests.\(UUID().uuidString)"))
        let model = WatchSyncModel(scheduler: scheduler, defaults: defaults)
        await model.turnOn(sessions: Self.sessions, today: "2026-10-28")
        #expect(scheduler.asked == 1)
        #expect(model.status == .synced(scheduler.items.count))
        #expect(scheduler.items.count == 15)
        #expect(model.isEnabled)
    }

    @MainActor @Test func resyncNeverAsksAndDoesNothingWhileOff() async throws {
        let scheduler = FakeScheduler()
        scheduler.state = .notDetermined
        let defaults = try #require(UserDefaults(suiteName: "WatchSyncTests.\(UUID().uuidString)"))
        let model = WatchSyncModel(scheduler: scheduler, defaults: defaults)
        await model.resync(sessions: Self.sessions, today: "2026-10-28")
        #expect(scheduler.asked == 0)
        #expect(scheduler.items.isEmpty)
        defaults.set(true, forKey: "watch.sync")
        await model.resync(sessions: Self.sessions, today: "2026-10-28")
        #expect(scheduler.asked == 0)
        #expect(scheduler.items.isEmpty)
    }

    @MainActor @Test func refusedPermissionLeavesItOffAndASecondSyncOnlyChangesWhatMoved() async throws {
        let denied = FakeScheduler()
        denied.state = .denied
        let defaults = try #require(UserDefaults(suiteName: "WatchSyncTests.\(UUID().uuidString)"))
        let refused = WatchSyncModel(scheduler: denied, defaults: defaults)
        await refused.turnOn(sessions: Self.sessions, today: "2026-10-28")
        #expect(refused.status == .denied)
        #expect(!refused.isEnabled)

        let scheduler = FakeScheduler()
        let model = WatchSyncModel(scheduler: scheduler, defaults: defaults)
        await model.turnOn(sessions: Self.sessions, today: "2026-10-28")
        scheduler.log = []
        await model.resync(sessions: Self.sessions, today: "2026-10-28")
        #expect(scheduler.log.isEmpty)
        await model.resync(sessions: Self.sessions, today: "2026-10-31")
        #expect(scheduler.log.filter { $0.hasPrefix("remove") }.count == 2)
        #expect(scheduler.log.first?.hasPrefix("remove") == true)
        #expect(scheduler.items.count == 15)
    }

    @MainActor @Test func turningOffClearsTheSchedule() async throws {
        let scheduler = FakeScheduler()
        let defaults = try #require(UserDefaults(suiteName: "WatchSyncTests.\(UUID().uuidString)"))
        let model = WatchSyncModel(scheduler: scheduler, defaults: defaults)
        await model.turnOn(sessions: Self.sessions, today: "2026-10-28")
        await model.turnOff()
        #expect(scheduler.items.isEmpty)
        #expect(model.status == .off)
        #expect(!model.isEnabled)
    }

    @MainActor @Test func aDeviceWithoutSchedulingSupportSaysSo() async throws {
        let scheduler = FakeScheduler()
        scheduler.isSupported = false
        let defaults = try #require(UserDefaults(suiteName: "WatchSyncTests.\(UUID().uuidString)"))
        let model = WatchSyncModel(scheduler: scheduler, defaults: defaults)
        await model.turnOn(sessions: Self.sessions, today: "2026-10-28")
        #expect(model.status == .unsupported)
    }
}
