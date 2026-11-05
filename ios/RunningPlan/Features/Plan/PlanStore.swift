import APIClient
import Foundation
import Observation

/// The saved plan the Next and Plan tabs show. Loaded from the server on launch and after a save. Session edits go
/// straight to the API while online, and the server's copy of the session replaces ours, so the next edit sends the
/// new revision. With an `OfflineSync`, an edit that cannot reach the server (or any edit while earlier ones wait) is
/// queued and shown at once, and the plan is kept on the device so the app opens offline.
@MainActor
@Observable
final class PlanStore {
    enum State: Equatable {
        case loading
        /// Signed out, or signed in with no plan: Next offers "Set a goal".
        case empty
        case loaded(Components.Schemas.PlanDetail)
        case failed(String)
    }

    private(set) var state: State = .loading
    private let loader: PlanLoading
    private let account: SignInService
    private let writer: SessionWriting
    let sync: OfflineSync?

    init(loader: PlanLoading, account: SignInService, writer: SessionWriting, sync: OfflineSync? = nil) {
        self.loader = loader
        self.account = account
        self.writer = writer
        self.sync = sync
        sync?.read = { [weak self] in self?.plan }
        sync?.write = { [weak self] plan in self?.set(.loaded(plan)) }
        sync?.clear = { [weak self] in self?.set(.empty) }
    }

    var plan: Components.Schemas.PlanDetail? {
        if case .loaded(let plan) = state { return plan }
        return nil
    }

    private func set(_ new: State) {
        if state != new { state = new }
        if case .loaded(let plan) = new { sync?.cache(plan: plan) }
    }

    /// Edits waiting to sync.
    var pendingChanges: Int { sync?.pendingCount ?? 0 }
    /// True while some queued edit can still be sent (not held for the user's choice).
    var syncWaiting: Bool { sync?.hasSendable ?? false }
    var syncNotice: String? { sync?.notice }
    func dismissSyncNotice() { sync?.dismissNotice() }
    var showsOfflineBanner: Bool { (sync?.isOffline ?? false) && pendingChanges > 0 }

    func load() async {
        guard await account.isSignedIn else {
            set(.empty)
            return
        }
        await sync?.activate()
        if let sync, sync.hasPending, let cached = sync.cachedPlan {
            // Edits made offline are not on the server yet: show them, push them, then load what the server holds.
            set(.loaded(cached))
            await syncNow()
            return
        }
        // The root view then syncs (its task keys on the load finishing), pulling changes from other devices.
        await run { try await self.loader.activePlan() }
    }

    /// After a save: show that plan without searching for it.
    func show(planId: String) async {
        // A sign-in may have changed the account since the queue on screen was loaded.
        await sync?.activate()
        await run { try await self.loader.plan(id: planId) }
    }

    private func run(keepOnError: Bool = false, _ fetch: () async throws -> Components.Schemas.PlanDetail?) async {
        let previous = state
        // A background reload (after a sync) never shows the spinner: it would race a load the user is waiting for.
        if plan == nil, !keepOnError { set(.loading) }
        do {
            set(try await fetch().map(State.loaded) ?? .empty)
        } catch PlanLoadError.signedOut {
            set(.empty)
        } catch is CancellationError {
            // A cancelled load must not leave the spinner up for good.
            if state == .loading { state = previous }
            return
        } catch PlanLoadError.offline {
            if keepOnError { return }
            // Offline: open on the plan as last seen, with any edits made since.
            if plan == nil, let cached = sync?.cachedPlan {
                set(.loaded(cached))
            } else {
                set(.failed("We couldn't reach the server. Check your connection and try again."))
            }
        } catch {
            if keepOnError { return }
            set(.failed("Something went wrong loading your plan. Please try again."))
        }
    }

    // MARK: Sync

    /// Pushes the offline queue and pulls what changed elsewhere (launch, coming to the front, after an edit).
    func syncNow() async {
        guard let sync, await account.isSignedIn else { return }
        await sync.activate()
        let outcome = await sync.run()
        if outcome.planDeleted { return }
        if outcome.reload || (outcome.applied > 0 && !sync.hasPending) {
            if let id = plan?.value1.value1.id {
                await run(keepOnError: true) { try await self.loader.plan(id: id) }
            } else {
                await run(keepOnError: true) { try await self.loader.activePlan() }
            }
        }
    }

    /// The first sync conflict waiting for the user.
    var conflict: ConflictModel? {
        guard let sync else { return nil }
        for conflict in sync.conflicts {
            if let model = ConflictModel(conflict: conflict, queue: sync.state.queue) { return model }
        }
        return nil
    }

    func keepMine(_ model: ConflictModel) async {
        sync?.keepMine(key: model.key)
        await syncNow()
    }

    func useOtherVersion(_ model: ConflictModel) {
        sync?.useServer(key: model.key)
    }

    // MARK: Edits

    /// Sends the edits in order. Returns a sentence for the screen when one fails (the ones before it stay applied).
    func apply(_ edits: [SessionEdit]) async -> String? {
        for edit in edits {
            if let error = await write({ try await self.writer.update(id: edit.sessionId, revision: edit.revision, edit.update) }, queued: { self.queueUpdate(edit) }) { return error }
        }
        return nil
    }

    func create(_ session: Components.Schemas.SessionCreate) async -> String? {
        guard let planId = plan?.value1.value1.id else { return "Your plan isn't loaded yet. Please try again." }
        return await write({ try await self.writer.create(planId: planId, session) }, queued: { self.queueCreate(planId: planId, session) })
    }

    func delete(sessionId: String, revision: Int) async -> String? {
        await write({ try await self.writer.delete(id: sessionId, revision: revision) }, queued: { self.queueDelete(sessionId: sessionId, revision: revision) })
    }

    /// `id` is made once by the caller and reused for a retry, so a check-in the server already stored is not doubled.
    func checkIn(sessionId: String, feeling: BeforeFeeling, id: String) async -> String? {
        await sendCheckIn({ try await self.writer.checkIn(sessionId: sessionId, feeling: feeling, id: id) }, queued: { self.queueCheckIn(sessionId: sessionId, id: id, .before(feeling)) })
    }

    /// The after-session check-in from DK-CheckIn; `id` as above.
    func checkIn(sessionId: String, after answer: AfterCheckIn, id: String) async -> String? {
        await sendCheckIn({ try await self.writer.checkIn(sessionId: sessionId, after: answer, id: id) }, queued: { self.queueCheckIn(sessionId: sessionId, id: id, .after(answer)) })
    }

    private func sendCheckIn(_ body: () async throws -> Void, queued: () -> Bool) async -> String? {
        await sync?.activate()
        if sync?.hasPending == true, queued() { return nil }
        do {
            try await body()
            return nil
        } catch SessionWriteError.offline where sync != nil && queued() {
            return nil
        } catch SessionWriteError.invalid {
            // Most likely an earlier answer was stored but its reply lost, and this one differs.
            return "We may already have your check-in for this session. Thanks."
        } catch {
            return Self.message(for: error)
        }
    }

    /// A session the server changed outside this store's own edits (a match confirmed or undone).
    func replace(session: Components.Schemas.Session, planContentRevision: Int, warnings: [Components.Schemas.Warning]) {
        merge(.init(session: session, planContentRevision: planContentRevision, warnings: warnings))
    }

    /// Interim "Delete plan" (until Goal and settings, 3.7). On success, or when the plan is already gone, the store goes
    /// back to the "Set a goal" state. Returns a sentence for the screen when it fails; the plan then stays.
    /// Online only: a plan delete is not queued.
    func deletePlan() async -> String? {
        guard let detail = plan else { return "Your plan isn't loaded yet. Please try again." }
        let id = detail.value1.value1.id
        do {
            try await writer.deletePlan(id: id, revision: detail.value1.value1.revision)
            set(.empty)
            return nil
        } catch SessionWriteError.notFound {
            set(.empty)
            return nil
        } catch SessionWriteError.conflict {
            await show(planId: id)
            return "Your plan changed somewhere else. We've loaded the latest version; delete it again if you still want to."
        } catch SessionWriteError.offline {
            return "We couldn't reach the server. Check your connection and try again."
        } catch SessionWriteError.signedOut {
            return "You've been signed out. Sign in again to delete your plan."
        } catch {
            return "Something went wrong deleting your plan. Please try again."
        }
    }

    private func write(_ body: () async throws -> Components.Schemas.SessionWriteResult, queued: () -> Bool) async -> String? {
        // Once anything waits, later edits wait behind it: they were made on the revisions the queue will produce.
        await sync?.activate()
        if sync?.hasPending == true, queued() { return nil }
        do {
            merge(try await body())
            return nil
        } catch SessionWriteError.offline where sync != nil && queued() {
            return nil
        } catch SessionWriteError.conflict {
            // Changed elsewhere: show the latest so the user can redo the change on it.
            if let id = plan?.value1.value1.id { await show(planId: id) }
            return "This session changed somewhere else. We've loaded the latest version; please make your change again."
        } catch {
            return Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case SessionWriteError.offline: "We couldn't reach the server. Check your connection and try again."
        case SessionWriteError.signedOut: "You've been signed out. Sign in again to change your plan."
        case SessionWriteError.notFound: "That session is no longer in your plan."
        case SessionWriteError.invalid: "The server didn't accept this session. Check each step's time, distance and pace, then try again."
        default: "Something went wrong saving your change. Please try again."
        }
    }

    /// Puts the server's copy of the session (or its tombstone) in the plan, with the plan's new revision and warnings.
    private func merge(_ result: Components.Schemas.SessionWriteResult) {
        guard var detail = plan else { return }
        let id = result.session.value1.id
        if let index = detail.value2.sessions.firstIndex(where: { $0.value1.id == id }) {
            detail.value2.sessions[index] = result.session
        } else {
            detail.value2.sessions.append(result.session)
        }
        detail.value1.value3.contentRevision = result.planContentRevision
        detail.value2.warnings = result.warnings
        set(.loaded(detail))
    }

    // MARK: Offline

    private func liveSession(_ id: String) -> Components.Schemas.Session? {
        plan?.value2.sessions.first { $0.value1.id == id && $0.value1.deletedAt == nil }
    }

    /// Queues the edit and shows its result on this device. False when it cannot be queued (nothing loaded).
    private func queueUpdate(_ edit: SessionEdit) -> Bool {
        guard let sync, let current = liveSession(edit.sessionId) else { return false }
        sync.enqueue(.sessionUpdate(key: OfflineSync.newKey(), id: edit.sessionId, baseRevision: edit.revision, edit.update))
        put(SessionEditing.apply(edit.update, to: current, now: sync.now))
        return true
    }

    private func queueCreate(planId: String, _ create: Components.Schemas.SessionCreate) -> Bool {
        guard let sync, plan != nil else { return false }
        sync.enqueue(.sessionCreate(key: OfflineSync.newKey(), planId: planId, create))
        put(SessionEditing.created(planId: planId, create, now: sync.now))
        return true
    }

    private func queueDelete(sessionId: String, revision: Int) -> Bool {
        guard let sync, let current = liveSession(sessionId) else { return false }
        switch sync.enqueue(.sessionDelete(key: OfflineSync.newKey(), id: sessionId, baseRevision: revision)) {
        case .cancelled:
            // Created and deleted before the server ever saw it.
            if var detail = plan {
                detail.value2.sessions.removeAll { $0.value1.id == sessionId }
                set(.loaded(detail))
            }
        case .queued:
            put(SessionEditing.deleted(current, now: sync.now))
        }
        return true
    }

    private func queueCheckIn(sessionId: String, id: String, _ fields: Components.Schemas.CheckInFields) -> Bool {
        guard let sync, liveSession(sessionId) != nil else { return false }
        sync.enqueue(.checkIn(key: OfflineSync.newKey(), id: id, sessionId: sessionId, fields))
        return true
    }

    private func put(_ session: Components.Schemas.Session) {
        guard var detail = plan else { return }
        if let index = detail.value2.sessions.firstIndex(where: { $0.value1.id == session.value1.id }) {
            detail.value2.sessions[index] = session
        } else {
            detail.value2.sessions.append(session)
        }
        set(.loaded(detail))
    }
}
