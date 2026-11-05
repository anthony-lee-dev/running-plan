import APIClient
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import RunningPlan

private actor Loader: PlanLoading {
    var offline = false
    private(set) var calls: [String] = []
    func setOffline(_ value: Bool) { offline = value }

    func activePlan() async throws -> Components.Schemas.PlanDetail? {
        calls.append("active")
        if offline { throw PlanLoadError.offline }
        return try PlanFixture.detail()
    }

    func plan(id: String) async throws -> Components.Schemas.PlanDetail? {
        calls.append("plan \(id)")
        if offline { throw PlanLoadError.offline }
        return try PlanFixture.detail(id: id)
    }
}

private actor SignedIn: SignInService {
    var isSignedIn: Bool { true }
    func startEmailSignIn(email: String) async throws {}
    func verify(email: String, code: String) async throws {}
}

/// First `activePlan` finds nothing; later ones find the plan. Records the store's state seen while fetching.
private actor ScriptedLoader: PlanLoading {
    var calls = 0
    var seen: [PlanStore.State] = []
    var probe: (@MainActor @Sendable () -> PlanStore.State)?
    var cancelOnPlanById = false

    func configure(probe: @escaping @MainActor @Sendable () -> PlanStore.State, cancelOnPlanById: Bool = false) {
        self.probe = probe
        self.cancelOnPlanById = cancelOnPlanById
    }

    func activePlan() async throws -> Components.Schemas.PlanDetail? {
        calls += 1
        if let probe { seen.append(await probe()) }
        return calls == 1 ? nil : try PlanFixture.detail()
    }

    func plan(id: String) async throws -> Components.Schemas.PlanDetail? {
        if let probe { seen.append(await probe()) }
        if cancelOnPlanById { throw CancellationError() }
        return try PlanFixture.detail(id: id)
    }
}

@MainActor
struct PlanStoreSpinnerTests {
    @Test func aCancelledLoadDoesNotLeaveTheSpinnerUp() async throws {
        let loader = ScriptedLoader()
        let store = PlanStore(loader: loader, account: SignedIn(), writer: FakeWriter())
        await store.load()
        #expect(store.state == .empty)
        await loader.configure(probe: { store.state }, cancelOnPlanById: true)

        await store.show(planId: PlanFixture.planID)

        #expect(store.state == .empty)
    }

    @Test func aReloadAfterSyncNeverShowsTheSpinner() async throws {
        let loader = ScriptedLoader()
        let service = FakeSyncService { _, _ in try response(plans: [try planJSON()]) }
        let sync = OfflineSync(store: MemoryOfflineStore(), service: service, scope: { "test|user" })
        let store = PlanStore(loader: loader, account: SignedIn(), writer: FakeWriter(), sync: sync)
        await store.load()
        await loader.configure(probe: { store.state })

        await store.syncNow()

        #expect(await loader.seen == [.empty])
        #expect(store.plan != nil)
    }

    @Test func aPullThatBeganBeforeADeleteDoesNotBringThePlanBack() async throws {
        let service = FakeSyncService { _, _ in try response() }
        let sync = OfflineSync(store: MemoryOfflineStore(), service: service, scope: { "test|user" })
        let loader = Loader()
        let store = PlanStore(loader: loader, account: SignedIn(), writer: FakeWriter(), sync: sync)
        await store.load()
        #expect(await store.deletePlan() == nil)
        #expect(store.state == .empty)

        // The pull still lists the plan as live.
        service.handler = { _, _ in try response(plans: [try planJSON()]) }
        await store.syncNow()

        #expect(store.state == .empty)
    }
}

@MainActor
struct OfflinePlanStoreTests {
    private func store(
        writer: FakeWriter = FakeWriter(.failure(.offline)), loader: Loader = Loader(), sync service: FakeSyncService = FakeSyncService(),
        offlineStore: OfflineStoring = MemoryOfflineStore()
    ) async -> PlanStore {
        let sync = OfflineSync(store: offlineStore, service: service, scope: { "test|user" })
        let store = PlanStore(loader: loader, account: SignedIn(), writer: writer, sync: sync)
        await store.load()
        return store
    }

    @Test func anEditMadeOfflineShowsAtOnceAndWaitsInTheQueue() async throws {
        let store = await store()
        let error = await store.apply([SessionEdit(sessionId: syncSession, revision: 1, update: .init(title: "Mine"))])

        #expect(error == nil)
        let shown = localSession(store.plan)
        #expect(shown?.value2.title == "Mine")
        #expect(shown?.value2.owner == .user)
        #expect(shown?.value1.revision == 2)
        #expect(store.pendingChanges == 1)
        #expect(store.sync?.state.queue.operations.first?.baseRevision == 1)
    }

    @Test func onceAnEditWaitsLaterEditsQueueBehindItWithoutTryingTheServer() async throws {
        let writer = FakeWriter(.failure(.offline))
        let store = await store(writer: writer)
        _ = await store.apply([SessionEdit(sessionId: syncSession, revision: 1, update: .init(title: "One"))])
        _ = await store.apply([SessionEdit(sessionId: syncSession, revision: 2, update: .init(notes: "Two"))])

        #expect(await writer.calls.count == 1)
        #expect(store.sync?.state.queue.operations.map(\.baseRevision) == [1, 2])
        #expect(localSession(store.plan)?.value1.revision == 3)
    }

    @Test func withoutTheQueueOfflineStillShowsAnError() async throws {
        let store = PlanStore(loader: Loader(), account: SignedIn(), writer: FakeWriter(.failure(.offline)))
        await store.load()
        let error = await store.apply([SessionEdit(sessionId: syncSession, revision: 1, update: .init(title: "Mine"))])
        #expect(error?.contains("connection") == true)
    }

    @Test func aCheckInMadeOfflineIsQueuedWithItsOwnId() async throws {
        let store = await store()
        #expect(await store.checkIn(sessionId: syncSession, feeling: .tired, id: "55555555-5555-4555-8555-555555555555") == nil)
        let op = try #require(store.sync?.state.queue.operations.first)
        #expect(op.entity == .checkIn("55555555-5555-4555-8555-555555555555"))
        #expect(op.checkInSessionId == syncSession)
    }

    @Test func aSessionDeletedOfflineIsHiddenAtOnce() async throws {
        let store = await store()
        #expect(await store.delete(sessionId: syncSession, revision: 1) == nil)
        #expect(localSession(store.plan)?.value1.deletedAt != nil)
        #expect(store.sync?.state.queue.operations.count == 1)
    }

    @Test func aSessionAddedAndRemovedOfflineLeavesNothingToSync() async throws {
        let store = await store()
        let content = try decode(Components.Schemas.SessionContent.self, #"{"date":"2026-10-29","type":"rest","title":"Rest day"}"#)
        let id = "99999999-9999-4999-8999-999999999999"
        #expect(await store.create(.init(value1: content, value2: .init(id: id))) == nil)
        #expect(localSession(store.plan, id)?.value2.title == "Rest day")
        #expect(await store.delete(sessionId: id, revision: 1) == nil)
        #expect(localSession(store.plan, id) == nil)
        #expect(store.pendingChanges == 0)
    }

    @Test func theAppOpensOfflineOnThePlanItLastSaw() async throws {
        let offlineStore = MemoryOfflineStore()
        _ = await store(offlineStore: offlineStore)

        let loader = Loader()
        await loader.setOffline(true)
        let reopened = await store(loader: loader, offlineStore: offlineStore)

        #expect(reopened.plan?.value1.value1.id == PlanFixture.planID)
    }

    @Test func syncingPushesTheQueueThenReloadsTheWarnings() async throws {
        let loader = Loader()
        let service = FakeSyncService { _, ops in
            try response(results: ops.map { result($0.idempotencyKey, "applied", revision: 2) })
        }
        let store = await store(loader: loader, sync: service)
        _ = await store.apply([SessionEdit(sessionId: syncSession, revision: 1, update: .init(title: "Mine"))])

        await store.syncNow()

        #expect(store.pendingChanges == 0)
        #expect(await loader.calls.last == "plan \(PlanFixture.planID)")
    }

    @Test func aConflictIsReadyForTheSheetAndKeepMineSendsItAgain() async throws {
        let service = FakeSyncService { _, ops in
            if ops.first?.baseRevision == 1 {
                return try response(results: [result(ops[0].idempotencyKey, "conflict", server: sessionJSON(revision: 5, title: "Theirs"))])
            }
            return try response(results: ops.map { result($0.idempotencyKey, "applied", revision: 6) })
        }
        let store = await store(sync: service)
        _ = await store.apply([SessionEdit(sessionId: syncSession, revision: 1, update: .init(title: "Mine"))])
        await store.syncNow()

        let model = try #require(store.conflict)
        #expect(model.title == "Theirs")
        #expect(model.rows == [.init(field: "Title", mine: "Mine", theirs: "Theirs")])

        await store.keepMine(model)

        #expect(store.conflict == nil)
        #expect(store.pendingChanges == 0)
    }
}
