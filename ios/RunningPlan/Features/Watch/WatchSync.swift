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


/// The words about the watch on the session page and in Watch settings (design §8.4, issue #100). Pure.
enum WatchStatusCopy {
    struct Line: Equatable {
        let text: String
        /// Show the Open Settings button: only the user can allow the permission again.
        let offersSettings: Bool
    }

    static let notAllowed = "Running Plan can't add workouts. Allow it in Settings."

    /// `2026-11-04` as `Tue 4 Nov`.
    static func day(_ date: String) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return date }
        return "\(PlanPreview.weekdayName(PlanPreview.dayNumber(date))) \(parts[2]) \(PlanPreview.months[parts[1] - 1])"
    }

    /// The status line under a run on the session page. Nil for sessions the watch never gets (strength, custom, rest),
    /// ones already done, skipped or past, and a device that cannot schedule workouts.
    static func line(
        for session: Components.Schemas.Session, in sessions: [Components.Schemas.Session], status: WatchSyncModel.Status,
        limit: Int, today: String
    ) -> Line? {
        let s = session.value2
        guard s.status != .done, s.status != .skipped, s.date >= today, let plan = WatchWorkoutMapper.plan(for: session) else { return nil }
        switch status {
        case .unsupported:
            return nil
        case .off:
            return Line(text: "Not on your watch. Turn on in Watch settings.", offersSettings: false)
        case .denied:
            return Line(text: notAllowed, offersSettings: true)
        case .synced:
            let key = WatchItem(id: plan.id, date: s.date, plan: plan).key
            let inWindow = WatchSync.window(sessions: sessions, today: today, limit: limit).contains { $0.key == key }
            return inWindow
                ? Line(text: "On your watch: in the Workout app for \(day(s.date)).", offersSettings: false)
                : Line(text: "Goes to your watch closer to the day.", offersSettings: false)
        }
    }

    /// The status line in the Watch settings sheet; `through` is the last day in the window.
    static func settingsLine(status: WatchSyncModel.Status, count: Int, through: String?) -> Line {
        switch status {
        case .unsupported:
            return Line(text: "Needs an iPhone paired with an Apple Watch.", offersSettings: false)
        case .off:
            return Line(text: "Off. Your runs stay in this app.", offersSettings: false)
        case .denied:
            return Line(text: notAllowed, offersSettings: true)
        case .synced:
            guard let through, count > 0 else {
                return Line(text: "On. Your next runs go to the Workout app as they come up.", offersSettings: false)
            }
            let text = count == 1
                ? "Your next run is in the Workout app, on \(day(through))."
                : "Your next \(count) runs are in the Workout app, up to \(day(through))."
            return Line(text: text, offersSettings: false)
        }
    }
}

/// Keeps the watch's schedule in step with the plan while the user wants it. The setting (the user's intent) is kept
/// apart from the permission: a refused or revoked permission shows as `.denied` and sync resumes when it is back.
/// The setting and the "asked" flag are stored on this iPhone per account. It asks for permission only from
/// `turnOn` (a tap), never from a resync.
@MainActor @Observable
final class WatchSyncModel {
    enum Status: Equatable {
        case off
        case unsupported
        case denied
        case synced(Int)
    }

    private(set) var status: Status = .off
    /// The runs kept on the watch as of the last sync, soonest first.
    private(set) var window: [WatchItem] = []
    private(set) var accountId: String?
    /// The user wants sync (the switch), whatever the permission says.
    private(set) var wantsSync = false
    /// The turn-on card was answered, or the switch was used.
    private(set) var asked = false
    private let scheduler: WatchScheduling
    private let defaults: UserDefaults
    private var accountKnown = false
    private static let ownerKey = "watch.owner"

    init(scheduler: WatchScheduling = LiveWatchScheduler(), defaults: UserDefaults = .standard) {
        self.scheduler = scheduler
        self.defaults = defaults
        if !scheduler.isSupported { status = .unsupported }
    }

    var isSupported: Bool { scheduler.isSupported }
    /// How many runs the window holds, so the settings sheet and the session page agree.
    var windowLimit: Int { scheduler.maxWorkouts }
    /// Show the one-time "Put your runs on your Apple Watch?" card.
    var shouldOfferTurnOn: Bool { isSupported && accountId != nil && !asked && !wantsSync }

    private func syncKey(_ id: String) -> String { "watch.sync.\(id)" }
    private func askedKey(_ id: String) -> String { "watch.asked.\(id)" }

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

    /// "Not now" on the card.
    func markAsked() async {
        await serialized {
            guard let id = self.accountId else { return }
            self.asked = true
            self.defaults.set(true, forKey: self.askedKey(id))
        }
    }

    func resync(sessions: [Components.Schemas.Session], today: String) async {
        await serialized { await self.doResync(sessions: sessions, today: today) }
    }

    /// Removes everything the app scheduled. The setting stays as it is, so the next plan syncs when it is saved.
    func clearAll() async {
        await serialized { await self.doClear() }
    }

    /// The one call the app makes when the plan, the account or the foreground changes. Only `.loaded` syncs and only
    /// `.empty` clears: loading, offline and error leave the watch alone. `account` is nil when signed out.
    func update(state: PlanStore.State, account: String?, today: String) async {
        await serialized {
            await self.doSetAccount(account)
            switch state {
            case .loaded(let plan): await self.doResync(sessions: plan.value2.sessions, today: today)
            case .empty: await self.doClear()
            case .loading, .failed: break
            }
        }
    }

    private func doSetAccount(_ id: String?) async {
        if accountKnown, id == accountId { return }
        accountKnown = true
        accountId = id
        wantsSync = id.map { defaults.bool(forKey: syncKey($0)) } ?? false
        asked = id.map { defaults.bool(forKey: askedKey($0)) } ?? false
        // What is on the watch belongs to the account that put it there: sign-out, or another account, removes it.
        if let owner = defaults.string(forKey: Self.ownerKey), owner != id { await removeEverything() }
        window = []
        status = !scheduler.isSupported ? .unsupported : (wantsSync ? .synced(0) : .off)
    }

    private func doTurnOn(sessions: [Components.Schemas.Session], today: String) async {
        guard scheduler.isSupported else { return status = .unsupported }
        guard let id = accountId else { return }
        wantsSync = true
        asked = true
        defaults.set(true, forKey: syncKey(id))
        defaults.set(true, forKey: askedKey(id))
        var state = await scheduler.authorization()
        if state == .notDetermined { state = await scheduler.requestAuthorization() }
        guard state == .authorized else { return status = .denied }
        await sync(sessions: sessions, today: today)
    }

    private func doTurnOff() async {
        guard let id = accountId else { return }
        wantsSync = false
        asked = true
        defaults.set(false, forKey: syncKey(id))
        defaults.set(true, forKey: askedKey(id))
        status = scheduler.isSupported ? .off : .unsupported
        await removeEverything()
    }

    private func doClear() async {
        await removeEverything()
        status = !scheduler.isSupported ? .unsupported : (wantsSync ? .synced(0) : .off)
    }

    private func removeEverything() async {
        window = []
        defaults.removeObject(forKey: Self.ownerKey)
        guard scheduler.isSupported, await scheduler.authorization() == .authorized else { return }
        for item in await scheduler.scheduled() { await scheduler.remove(item) }
    }

    /// Brings the schedule up to date. Does nothing unless the user wants it; if permission is gone it only says so.
    private func doResync(sessions: [Components.Schemas.Session], today: String) async {
        guard scheduler.isSupported else { return status = .unsupported }
        guard wantsSync else { return status = .off }
        guard await scheduler.authorization() == .authorized else { return status = .denied }
        await sync(sessions: sessions, today: today)
    }

    private func sync(sessions: [Components.Schemas.Session], today: String) async {
        let desired = WatchSync.window(sessions: sessions, today: today, limit: scheduler.maxWorkouts)
        let changes = WatchSync.diff(desired: desired, existing: await scheduler.scheduled())
        for item in changes.remove { await scheduler.remove(item) }
        for item in changes.add { await scheduler.schedule(item) }
        if let id = accountId { defaults.set(id, forKey: Self.ownerKey) }
        window = desired
        status = .synced(desired.count)
    }
}
