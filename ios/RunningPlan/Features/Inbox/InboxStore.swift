import APIClient
import Foundation
import Observation

/// The import inbox: workouts waiting for review, the Health import, and the actions on a card. Server calls go
/// straight to the API (the offline queue is slice 5). Kept in memory: the list is re-read from the server.
@MainActor
@Observable
final class InboxStore {
    typealias Activity = Components.Schemas.Activity

    private(set) var activities: [Activity] = []
    private(set) var loaded = false
    /// Every imported run, matched or not, once the session page or the all-runs list has asked for it.
    private(set) var allRuns: [Activity] = []
    private(set) var allRunsLoaded = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var lastSynced: Date?
    /// The server's suggested session per activity id, from this run's uploads (the server does not store them).
    private(set) var suggestions: [String: String] = [:]
    /// The match just confirmed, so the screen can offer Undo.
    private(set) var lastConfirmed: (sessionId: String, label: String)?
    /// The session and run just matched from the inbox: DK-CheckIn shows plan vs actual and asks how it felt (§8.3).
    private(set) var pendingCheckIn: CheckInTarget?

    struct CheckInTarget: Identifiable, Equatable {
        let session: Components.Schemas.Session
        let activity: Components.Schemas.ActivityFields
        var id: String { session.value1.id }
    }

    private let service: InboxServing
    private let health: HealthImporting
    private let plans: PlanStore
    private let now: () -> Date
    private let zone: () -> TimeZone
    /// How far back a Health import looks.
    static let lookbackDays = 30

    init(service: InboxServing, health: HealthImporting, plans: PlanStore, now: @escaping () -> Date = Date.init, zone: @escaping () -> TimeZone = { .current }) {
        self.service = service
        self.health = health
        self.plans = plans
        self.now = now
        self.zone = zone
    }

    var healthAvailable: Bool { health.isAvailable }
    var count: Int { activities.count }

    func model(today: String) -> InboxModel {
        InboxModel(activities: activities, sessions: plans.plan?.value2.sessions ?? [], suggestions: suggestions, today: today)
    }

    /// Opens the screen: reads Health when the user has already allowed it, then the inbox.
    func load() async {
        var importError: String?
        // Not again within five minutes of the last import: uploads dedupe, but each open need not re-read Health.
        let recent = lastSynced.map { now().timeIntervalSince($0) < 300 } ?? false
        if health.isAvailable, !recent, !(await health.needsAccess()) {
            await importFromHealth()
            importError = error
        }
        await refresh()
        if error == nil { error = importError }
    }

    func refresh() async {
        await run { self.activities = try await self.service.inbox(); self.loaded = true }
    }

    /// Reads every imported run (matched ones carry their session), for the session page and the all-runs list.
    func loadAllRuns() async {
        await run { self.allRuns = try await self.service.allRuns(); self.allRunsLoaded = true }
    }

    func runs(today: String) -> RunsModel {
        RunsModel(activities: allRuns, sessions: plans.plan?.value2.sessions ?? [], today: today)
    }

    /// From the user's tap: asks for Health access if needed, then imports.
    func syncHealth() async {
        guard health.isAvailable else { error = "Health isn't available on this device. You can add a run by hand."; return }
        busy = true
        defer { busy = false }
        do {
            if await health.needsAccess() { try await health.requestAccess() }
        } catch {
            self.error = "We couldn't ask Health for access. You can allow it in Settings, or add a run by hand."
            return
        }
        await importFromHealth()
        let importError = error
        await refresh()
        if error == nil { error = importError }
    }

    private func importFromHealth() async {
        await run {
            let since = Calendar.current.date(byAdding: .day, value: -Self.lookbackDays, to: self.now()) ?? self.now()
            for batch in HealthWorkoutMapper.batches(try await self.health.workouts(since: since)) {
                self.suggestions.merge(try await self.service.upload(batch)) { _, new in new }
            }
            self.lastSynced = self.now()
        }
    }

    /// A run typed in by hand. `id` is made once per entry sheet. Returns true when it was stored.
    func addManual(id: String, localDate: String, distanceKm: Double, minutes: Double) async -> Bool {
        guard let input = HealthWorkoutMapper.manualRun(id: id, localDate: localDate, distanceKm: distanceKm, minutes: minutes, now: now(), zone: zone()) else {
            error = "Check the date, distance and time of that run."
            return false
        }
        let ok = await run { self.suggestions.merge(try await self.service.upload([input])) { _, new in new } }
        if ok { await refresh() }
        return ok && error == nil
    }

    func confirm(activityId: String, sessionId: String, label: String) async {
        await match(activityId: activityId, sessionId: sessionId, label: label, offerUndo: true)
    }

    /// Matches a run to a session from the session page or the all-runs list. If the session already had a run, that
    /// run goes back to the inbox; if the run was matched elsewhere, it moves and the other session is open again.
    func rematch(activityId: String, sessionId: String, label: String) async {
        await match(activityId: activityId, sessionId: sessionId, label: label, offerUndo: false)
    }

    private func match(activityId: String, sessionId: String, label: String, offerUndo: Bool) async {
        // The server then changes a second session (the old one goes back to planned), which the reply does not carry.
        let displaces = allRuns.contains { $0.value2.disposition == .matched && ($0.value2.id == activityId || $0.value2.match?.sessionId == sessionId) }
        // Kept before the lists reload, which drop the run from the inbox.
        let workout = (activities + allRuns).first { $0.value2.id == activityId }?.value1
        let ok = await run {
            let result = try await self.service.confirm(sessionId: sessionId, activityId: activityId)
            self.plans.replace(session: result.session, planContentRevision: result.planContentRevision, warnings: result.warnings)
            self.lastConfirmed = offerUndo ? (sessionId, label) : nil
            if offerUndo, let workout { self.pendingCheckIn = CheckInTarget(session: result.session, activity: workout) }
        }
        guard ok else { return }
        if displaces { await reloadPlan() }
        // Reload: the server may have moved another workout's match.
        await refreshLists()
    }

    /// The check-in was skipped, or saved: then Undo goes, since unmatching would leave the stored check-in feeding
    /// proposals for a session that is no longer done.
    func finishCheckIn(saved: Bool = false) {
        pendingCheckIn = nil
        if saved { lastConfirmed = nil }
    }

    /// Takes the run off this session; it returns to the inbox and the session to planned.
    func unmatch(sessionId: String) async {
        let ok = await run {
            let result = try await self.service.unmatch(sessionId: sessionId)
            self.plans.replace(session: result.session, planContentRevision: result.planContentRevision, warnings: result.warnings)
            self.lastConfirmed = nil
        }
        if ok { await refreshLists() }
    }

    func undo() async {
        guard let last = lastConfirmed else { return }
        let ok = await run {
            let result = try await self.service.unmatch(sessionId: last.sessionId)
            self.plans.replace(session: result.session, planContentRevision: result.planContentRevision, warnings: result.warnings)
            self.lastConfirmed = nil
            self.pendingCheckIn = nil
        }
        if ok { await refreshLists() }
    }

    /// An extra or ignored run back to the inbox.
    func backToInbox(_ activityId: String) async {
        let ok = await run { try await self.service.setDisposition(activityId: activityId, .inbox) }
        if ok { await refreshLists() }
    }

    private func reloadPlan() async {
        if let id = plans.plan?.value1.value1.id { await plans.show(planId: id) }
    }

    private func refreshLists() async {
        await refresh()
        if allRunsLoaded { await loadAllRuns() }
    }

    func addAsExtra(_ activityId: String) async { await setDisposition(activityId, .extra) }
    func ignore(_ activityId: String) async { await setDisposition(activityId, .ignored) }

    private func setDisposition(_ activityId: String, _ disposition: Components.Schemas.ActivityUpdate.dispositionPayload) async {
        let ok = await run { try await self.service.setDisposition(activityId: activityId, disposition) }
        if ok {
            activities.removeAll { $0.value2.id == activityId }
            if allRunsLoaded { await loadAllRuns() }
        }
    }

    /// Runs a server call, turning a failure into a sentence. True when it succeeded.
    @discardableResult
    private func run(_ body: () async throws -> Void) async -> Bool {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await body()
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = Self.message(for: error)
            return false
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case InboxError.offline: "We couldn't reach the server. Check your connection and try again."
        case InboxError.signedOut: "You've been signed out. Sign in again to import runs."
        case InboxError.forbidden: "This device can't upload workouts."
        case InboxError.notFound: "That workout or session is no longer there. Pull to refresh."
        case InboxError.invalid: "The server didn't accept that. Please check it and try again."
        default: "Something went wrong with the import. Please try again."
        }
    }
}
