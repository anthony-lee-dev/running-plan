import APIClient
import Foundation
import Observation
import WorkoutKit

/// A workout on the watch's schedule, identified by its plan id and local date (`YYYY-MM-DD`). Two items with the same
/// key are the same entry, whatever else the scheduler hands back.
struct WatchItem {
    let id: UUID
    let date: String
    let plan: WorkoutPlan

    var key: String { "\(id.uuidString) \(date)" }

    init(id: UUID, date: String, plan: WorkoutPlan) {
        self.id = id
        self.date = date
        self.plan = plan
    }

    /// The date as the scheduler wants it: year, month and day only, never through `Date` or a time zone.
    var components: DateComponents {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        return DateComponents(year: parts.count == 3 ? parts[0] : nil, month: parts.count == 3 ? parts[1] : nil, day: parts.count == 3 ? parts[2] : nil)
    }

    init?(scheduled: ScheduledWorkoutPlan) {
        guard let year = scheduled.date.year, let month = scheduled.date.month, let day = scheduled.date.day else { return nil }
        self.init(id: scheduled.plan.id, date: String(format: "%04d-%02d-%02d", year, month, day), plan: scheduled.plan)
    }
}

/// The rolling window of upcoming sessions kept on the watch (design §8.4: the Workout app holds up to 15).
enum WatchSync {
    static let maxWorkouts = 15

    /// The next `limit` planned run sessions from `today` on, soonest first.
    static func window(sessions: [Components.Schemas.Session], today: String, limit: Int = maxWorkouts) -> [WatchItem] {
        let upcoming = sessions
            .filter { $0.value1.deletedAt == nil && $0.value2.status != .done && $0.value2.status != .skipped && $0.value2.date >= today }
            .sorted { ($0.value2.date, $0.value1.id) < ($1.value2.date, $1.value1.id) }
        var items: [WatchItem] = []
        for session in upcoming {
            guard items.count < limit else { break }
            guard let plan = WatchWorkoutMapper.plan(for: session) else { continue }
            items.append(WatchItem(id: plan.id, date: session.value2.date, plan: plan))
        }
        return items
    }

    /// What to take off and put on so the schedule matches `desired`. Everything scheduled that is not wanted is
    /// removed (past entries too, since they count toward the scheduler's cap), and the removals run first.
    static func diff(desired: [WatchItem], existing: [WatchItem]) -> (remove: [WatchItem], add: [WatchItem]) {
        let wanted = Set(desired.map(\.key))
        let present = Set(existing.map(\.key))
        return (existing.filter { !wanted.contains($0.key) }, desired.filter { !present.contains($0.key) })
    }
}

enum WatchAuthorization: Equatable {
    case notDetermined, denied, authorized
}

/// The watch's schedule, as the sync needs it. `LiveWatchScheduler` is WorkoutKit; tests use a fake.
protocol WatchScheduling {
    var isSupported: Bool { get }
    var maxWorkouts: Int { get }
    func authorization() async -> WatchAuthorization
    func requestAuthorization() async -> WatchAuthorization
    func scheduled() async -> [WatchItem]
    func schedule(_ item: WatchItem) async
    func remove(_ item: WatchItem) async
}

struct LiveWatchScheduler: WatchScheduling {
    var isSupported: Bool { WorkoutScheduler.isSupported }
    var maxWorkouts: Int { min(WatchSync.maxWorkouts, WorkoutScheduler.maxAllowedScheduledWorkoutCount) }

    private func map(_ state: WorkoutScheduler.AuthorizationState) -> WatchAuthorization {
        switch state {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func authorization() async -> WatchAuthorization { map(await WorkoutScheduler.shared.authorizationState) }
    func requestAuthorization() async -> WatchAuthorization { map(await WorkoutScheduler.shared.requestAuthorization()) }
    func scheduled() async -> [WatchItem] { await WorkoutScheduler.shared.scheduledWorkouts.compactMap(WatchItem.init(scheduled:)) }
    func schedule(_ item: WatchItem) async { await WorkoutScheduler.shared.schedule(item.plan, at: item.components) }
    func remove(_ item: WatchItem) async { await WorkoutScheduler.shared.remove(item.plan, at: item.components) }
}

/// Keeps the watch's schedule in step with the plan while the user has it switched on. It asks for permission only
/// from `turnOn` (a tap), never from a background resync.
@MainActor @Observable
final class WatchSyncModel {
    enum Status: Equatable {
        case off
        case unsupported
        case denied
        case synced(Int)
    }

    private(set) var status: Status
    private let scheduler: WatchScheduling
    private let defaults: UserDefaults
    private static let key = "watch.sync"

    var isOn: Bool { status != .off && status != .denied && status != .unsupported }

    init(scheduler: WatchScheduling = LiveWatchScheduler(), defaults: UserDefaults = .standard) {
        self.scheduler = scheduler
        self.defaults = defaults
        status = defaults.bool(forKey: Self.key) ? .synced(0) : .off
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.key) }

    /// One change at a time: a background resync must not interleave with a tap's turn on or off.
    private var tail: Task<Void, Never>?

    private func serialized(_ op: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await op()
        }
        tail = task
        await task.value
    }

    func turnOn(sessions: [Components.Schemas.Session], today: String) async {
        await serialized { await self.doTurnOn(sessions: sessions, today: today) }
    }

    func turnOff() async {
        await serialized { await self.doTurnOff() }
    }

    func resync(sessions: [Components.Schemas.Session], today: String) async {
        await serialized { await self.doResync(sessions: sessions, today: today) }
    }

    private func doTurnOn(sessions: [Components.Schemas.Session], today: String) async {
        guard scheduler.isSupported else { return status = .unsupported }
        var state = await scheduler.authorization()
        if state == .notDetermined { state = await scheduler.requestAuthorization() }
        guard state == .authorized else {
            defaults.set(false, forKey: Self.key)
            return status = .denied
        }
        defaults.set(true, forKey: Self.key)
        await sync(sessions: sessions, today: today)
    }

    private func doTurnOff() async {
        defaults.set(false, forKey: Self.key)
        status = .off
        guard scheduler.isSupported, await scheduler.authorization() == .authorized else { return }
        for item in await scheduler.scheduled() { await scheduler.remove(item) }
    }

    /// Brings the schedule up to date after the plan changes. Does nothing unless switched on and already allowed.
    private func doResync(sessions: [Components.Schemas.Session], today: String) async {
        guard isEnabled, scheduler.isSupported, await scheduler.authorization() == .authorized else { return }
        await sync(sessions: sessions, today: today)
    }

    private func sync(sessions: [Components.Schemas.Session], today: String) async {
        let desired = WatchSync.window(sessions: sessions, today: today, limit: scheduler.maxWorkouts)
        let changes = WatchSync.diff(desired: desired, existing: await scheduler.scheduled())
        for item in changes.remove { await scheduler.remove(item) }
        for item in changes.add { await scheduler.schedule(item) }
        status = .synced(desired.count)
    }
}
