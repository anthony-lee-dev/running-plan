import APIClient
import Foundation
import Testing
@testable import RunningPlan

private func workout(
    _ id: String = "hk-1", type: Components.Schemas.WorkoutType = .running, duration: Double = 1994, distance: Double? = 5100,
    avg: Double? = 148, max: Double? = 171, zone: String = "America/Vancouver", product: String? = "Watch7,1", source: String = "Running Planner Watch"
) -> HealthWorkout {
    HealthWorkout(
        uuid: id, type: type, start: Date(timeIntervalSince1970: 1_792_994_000), timeZone: TimeZone(identifier: zone)!, durationSec: duration,
        distanceM: distance, avgHeartRate: avg, maxHeartRate: max, sourceName: source, productType: product
    )
}

struct HealthWorkoutMapperTests {
    @Test func aRunMapsToAnUploadRecordWithItsLocalDate() throws {
        let fields = try #require(HealthWorkoutMapper.input(workout())).value1
        #expect(fields.source == .apple_health)
        #expect(fields.externalId == "hk-1")
        #expect(fields.workoutType == .running)
        #expect(fields.localDate == "2026-10-25")
        #expect(fields.durationSec == 1994)
        #expect(fields.distanceM == 5100)
        #expect(fields.avgHeartRate == 148)
        #expect(fields.sourceApp == "Apple Watch")
    }

    // Issue #131: the climb comes from the workout's metadata; a bad value is dropped, not sent.
    @Test func elevationGainIsUploadedWhenInRangeAndDroppedOtherwise() throws {
        var w = workout()
        w.elevationGainM = 41.6
        #expect(try #require(HealthWorkoutMapper.input(w)).value1.elevationGainM == 42)
        w.elevationGainM = 20_000
        #expect(try #require(HealthWorkoutMapper.input(w)).value1.elevationGainM == nil)
        w.elevationGainM = nil
        #expect(try #require(HealthWorkoutMapper.input(w)).value1.elevationGainM == nil)
    }

    // Issue #134: the API refuses a whole batch when one sourceApp is over 64 UTF-16 units (JavaScript's length), and
    // Swift's prefix(64) counts characters, so one app with an emoji name would stop every later import.
    @Test func aSourceNameIsCutToTheServersLengthInUTF16Units() throws {
        let label = HealthWorkoutMapper.sourceLabel(sourceName: String(repeating: "🏃", count: 60), productType: nil)
        #expect(label.utf16.count <= 64)
        #expect(!label.isEmpty)
        let record = try #require(HealthWorkoutMapper.input(workout(product: nil, source: String(repeating: "🏃", count: 60)))).value1
        #expect((record.sourceApp ?? "").utf16.count <= 64)
    }

    // The Oct 31 2026 Watch run of issue #134 (4.42 km in 30:08). Documents that nothing in the mapping depends on a
    // workout's name; HealthKit's own name is never read.
    @Test func aWatchRunOf442KmMapsAsARun() throws {
        let fields = try #require(HealthWorkoutMapper.input(workout("hk-oct31", duration: 1808, distance: 4420, zone: "America/Toronto"))).value1
        #expect(fields.workoutType == .running)
        #expect(fields.durationSec == 1808)
        #expect(fields.distanceM == 4420)
    }

    @Test func otherAppsKeepTheirName() {
        #expect(HealthWorkoutMapper.sourceLabel(sourceName: "Garmin Connect", productType: nil) == "Garmin Connect")
        #expect(HealthWorkoutMapper.sourceLabel(sourceName: "Nike Run Club", productType: "iPhone16,1") == "Nike Run Club")
        #expect(HealthWorkoutMapper.sourceLabel(sourceName: "Anthony's Apple Watch", productType: "Watch6,2") == "Apple Watch")
    }

    @Test func outOfRangeOptionalFieldsAreDroppedSoTheBatchIsNotRefused() throws {
        let fields = try #require(HealthWorkoutMapper.input(workout(distance: 500_000, avg: 12, max: 300))).value1
        #expect(fields.distanceM == nil)
        #expect(fields.avgHeartRate == nil)
        #expect(fields.maxHeartRate == nil)
    }

    @Test(arguments: [0.0, 0.2, 90_000])
    func aRecordWithAnInvalidDurationIsSkipped(duration: Double) {
        #expect(HealthWorkoutMapper.input(workout(duration: duration)) == nil)
    }

    @Test func uploadsAreSplitIntoBatchesOf200() {
        let many = (0..<450).map { workout("hk-\($0)") } + [workout("bad", duration: 0)]
        let sizes = HealthWorkoutMapper.batches(many).map(\.count)
        let expected = [200, 200, 50]
        #expect(sizes == expected)
    }

    @Test func aManualRunIsStoredOnTheChosenDay() throws {
        let zone = TimeZone(identifier: "America/Vancouver")!
        let now = Date(timeIntervalSince1970: 1_793_080_000)
        let fields = try #require(HealthWorkoutMapper.manualRun(id: "m-1", localDate: "2026-10-26", distanceKm: 5, minutes: 30.5, now: now, zone: zone)).value1
        #expect(fields.source == .manual)
        #expect(fields.externalId == "m-1")
        #expect(fields.localDate == "2026-10-26")
        #expect(fields.durationSec == 1830)
        #expect(fields.distanceM == 5000)
        #expect(LocalDay.string(from: fields.startedAt, in: zone) == "2026-10-26")
    }

    @Test func aManualRunCannotBeInTheFutureOrEmpty() {
        let zone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_080_000) // 2026-10-27
        #expect(HealthWorkoutMapper.manualRun(id: "m", localDate: "2026-10-28", distanceKm: 5, minutes: 30, now: now, zone: zone) == nil)
        #expect(HealthWorkoutMapper.manualRun(id: "m", localDate: "2026-10-26", distanceKm: 5, minutes: 0, now: now, zone: zone) == nil)
        #expect(HealthWorkoutMapper.manualRun(id: "m", localDate: "2026-10-26", distanceKm: 900, minutes: 30, now: now, zone: zone) == nil)
    }
}

// MARK: Store

private actor FakeService: InboxServing {
    var waiting: [Components.Schemas.Activity]
    var uploads: [[String]] = []
    var confirmed: [(session: String, activity: String)] = []
    var dispositions: [String: String] = [:]
    var failure: InboxError?
    let session: Components.Schemas.Session

    init(waiting: [Components.Schemas.Activity], session: Components.Schemas.Session) {
        self.waiting = waiting
        self.session = session
    }

    func inbox() async throws -> [Components.Schemas.Activity] {
        if let failure { throw failure }
        return waiting
    }

    var everything: [Components.Schemas.Activity] = []
    var unmatched: [String] = []

    func setEverything(_ runs: [Components.Schemas.Activity]) { everything = runs }

    func allRuns() async throws -> [Components.Schemas.Activity] {
        if let failure { throw failure }
        return everything
    }

    func upload(_ inputs: [Components.Schemas.ActivityInput]) async throws -> [String: String] {
        if let failure { throw failure }
        uploads.append(inputs.map { $0.value1.externalId })
        return [:]
    }

    func confirm(sessionId: String, activityId: String) async throws -> Components.Schemas.MatchWriteResult {
        if let failure { throw failure }
        confirmed.append((sessionId, activityId))
        waiting.removeAll { $0.value2.id == activityId }
        var done = session
        done.value2.status = .done
        let match = Components.Schemas.Match(sessionId: sessionId, activityId: activityId, status: .confirmed, updatedAt: Date())
        return .init(match: match, session: done, planContentRevision: 9, warnings: [])
    }

    func unmatch(sessionId: String) async throws -> Components.Schemas.SessionWriteResult {
        unmatched.append(sessionId)
        return .init(session: session, planContentRevision: 10, warnings: [])
    }

    func setDisposition(activityId: String, _ disposition: Components.Schemas.ActivityUpdate.dispositionPayload) async throws {
        dispositions[activityId] = disposition.rawValue
    }

    func fail(_ error: InboxError?) { failure = error }
}

private struct FakeHealth: HealthImporting {
    var isAvailable = true
    var asks = true
    var found: [HealthWorkout] = []
    var byId: [String: HealthWorkout] = [:]
    var samples: RunSamples?
    func workout(uuid: String) async throws -> HealthWorkout? { byId[uuid] }
    func samples(forWorkout uuid: String) async throws -> RunSamples? { samples }
    func needsAccess() async -> Bool { asks }
    func requestAccess() async throws {}
    func workouts(since: Date) async throws -> [HealthWorkout] { found }
}

private struct FakeLoader: PlanLoading {
    let plan: Components.Schemas.PlanDetail
    func activePlan() async throws -> Components.Schemas.PlanDetail? { plan }
    func plan(id: String) async throws -> Components.Schemas.PlanDetail? { plan }
}

private struct SignedIn: SignInService {
    var isSignedIn: Bool { get async { true } }
    func startEmailSignIn(email: String) async throws {}
    func verify(email: String, code: String) async throws {}
}

private struct NoWrites: SessionWriting {
    func update(id: String, revision: Int, _ body: Components.Schemas.SessionUpdate) async throws -> Components.Schemas.SessionWriteResult { throw SessionWriteError.server }
    func create(planId: String, _ body: Components.Schemas.SessionCreate) async throws -> Components.Schemas.SessionWriteResult { throw SessionWriteError.server }
    func delete(id: String, revision: Int) async throws -> Components.Schemas.SessionWriteResult { throw SessionWriteError.server }
    func checkIn(sessionId: String, feeling: BeforeFeeling, id: String) async throws {}
    func checkIn(sessionId: String, after answer: AfterCheckIn, id: String) async throws {}
    func deletePlan(id: String, revision: Int) async throws { throw SessionWriteError.server }
}

@MainActor
struct InboxStoreTests {
    private func make(health: FakeHealth = FakeHealth(), activities: [Components.Schemas.Activity]? = nil) async throws -> (InboxStore, FakeService, PlanStore, String) {
        var plan = try PlanFixture.detail()
        let index = try #require(plan.value2.sessions.firstIndex { $0.value2.date == "2026-10-26" && $0.value2._type == .easy })
        plan.value2.sessions[index].value2.status = .planned
        let monday = plan.value2.sessions[index]
        let plans = PlanStore(loader: FakeLoader(plan: plan), account: SignedIn(), writer: NoWrites())
        await plans.load()
        let waiting = try activities ?? [activityFixture(id: "a1", date: "2026-10-26")]
        let service = FakeService(waiting: waiting, session: monday)
        let store = InboxStore(service: service, health: health, plans: plans, now: { Date(timeIntervalSince1970: 1_793_080_000) }, zone: { TimeZone(identifier: "UTC")! })
        return (store, service, plans, monday.value1.id)
    }

    @Test func confirmingAMatchMarksTheSessionDoneAndEmptiesTheInbox() async throws {
        let (store, service, plans, mondayId) = try await make()
        await store.refresh()
        #expect(store.count == 1)

        await store.confirm(activityId: "a1", sessionId: mondayId, label: "Easy run · 5 km")

        #expect(await service.confirmed.map(\.session) == [mondayId])
        #expect(store.count == 0)
        #expect(store.lastConfirmed?.label == "Easy run · 5 km")
        let session = try #require(plans.plan?.value2.sessions.first { $0.value1.id == mondayId })
        #expect(session.value2.status == .done)
        #expect(plans.plan?.value1.value3.contentRevision == 9)
    }

    @Test func confirmingAMatchAsksForAnAfterSessionCheckIn() async throws {
        let (store, _, _, mondayId) = try await make()
        await store.refresh()
        await store.confirm(activityId: "a1", sessionId: mondayId, label: "Easy run · 5 km")

        let pending = try #require(store.pendingCheckIn)
        #expect(pending.id == mondayId)
        #expect(pending.session.value2.status == .done)
        #expect(pending.activity.durationSec == 1994)
        #expect(pending.activity.distanceM == 5100)

        store.finishCheckIn()
        #expect(store.pendingCheckIn == nil)
        #expect(store.lastConfirmed != nil, "Skipping keeps Undo")
    }

    @Test func aSavedCheckInTakesAwayUndo() async throws {
        // Undo would leave the saved check-in feeding proposals for a session that is no longer done.
        let (store, _, _, mondayId) = try await make()
        await store.refresh()
        await store.confirm(activityId: "a1", sessionId: mondayId, label: "Easy run · 5 km")
        store.finishCheckIn(saved: true)
        #expect(store.pendingCheckIn == nil)
        #expect(store.lastConfirmed == nil)
    }

    @Test func aFailedMatchAsksForNoCheckIn() async throws {
        let (store, service, _, mondayId) = try await make()
        await store.refresh()
        await service.fail(.offline)
        await store.confirm(activityId: "a1", sessionId: mondayId, label: "Easy run · 5 km")
        #expect(store.pendingCheckIn == nil)
    }

    @Test func extraAndIgnoredLeaveTheInbox() async throws {
        let (store, service, _, _) = try await make(activities: [activityFixture(id: "a1", date: "2026-10-25"), activityFixture(id: "a2", date: "2026-10-25")])
        await store.refresh()
        await store.addAsExtra("a1")
        await store.ignore("a2")
        #expect(store.count == 0)
        #expect(await service.dispositions == ["a1": "extra", "a2": "ignored"])
    }

    @Test func syncingUploadsHealthWorkoutsAfterAskingForAccess() async throws {
        let health = FakeHealth(found: [workout("hk-1"), workout("hk-2", duration: 0)])
        let (store, service, _, _) = try await make(health: health)
        await store.syncHealth()
        #expect(await service.uploads == [["hk-1"]])
        #expect(store.lastSynced != nil)
    }

    @Test func openingTheInboxNeverAsksForHealthAccessItself() async throws {
        let (store, service, _, _) = try await make(health: FakeHealth(asks: true, found: [workout("hk-1")]))
        await store.load()
        #expect(await service.uploads.isEmpty)
        #expect(store.count == 1)
    }

    @Test func openingTheInboxImportsWhenAccessWasAlreadyGiven() async throws {
        let (store, service, _, _) = try await make(health: FakeHealth(asks: false, found: [workout("hk-1")]))
        await store.load()
        #expect(await service.uploads == [["hk-1"]])
    }

    // Issue #134: the session page's "Match a run" listed only what the server already held, never reading Health.
    @Test func openingASessionPageImportsFromHealthWhenAccessWasGiven() async throws {
        let (store, service, _, _) = try await make(health: FakeHealth(asks: false, found: [workout("hk-oct31")]))
        await store.openSessionPage()
        #expect(await service.uploads == [["hk-oct31"]])
        #expect(store.allRunsLoaded)
    }

    // Issue #131: opening a run's details re-reads it from Health and uploads only when Health now has a field the
    // stored run lacks (the server keeps the match and fills the gap).
    @Test func backfillUploadsARunThatGainedAFieldAndSkipsOneThatDidNot() async throws {
        var richer = workout("hk-a1")
        richer.elevationGainM = 55
        let (store, service, _, _) = try await make(health: FakeHealth(asks: false, byId: ["hk-a1": richer, "hk-a2": workout("hk-a2", avg: 148, max: nil)]))
        let stored = try activityFixture(id: "a1", date: "2026-10-26")
        let complete = try activityFixture(id: "a2", date: "2026-10-26")
        await service.setEverything([stored, complete])
        await store.loadAllRuns()

        await store.backfill(activityId: "a1")
        #expect(await service.uploads == [["hk-a1"]])
        await store.backfill(activityId: "a2")
        #expect(await service.uploads == [["hk-a1"]], "nothing new to fill in")
    }

    // Issue #131: the splits skeleton shows while Health is read, then goes; weather comes from the same read.
    @Test func detailsLoadSplitsAndWeatherThenStopLoading() async throws {
        var samples = RunSamples()
        samples.distance = (0..<20).map { DistanceSample(start: Double($0) * 100, end: Double($0 + 1) * 100, meters: 250) }
        samples.weather = RunWeather(temperatureC: 12, humidityPercent: 70, condition: "Cloudy")
        let (store, service, _, _) = try await make(health: FakeHealth(asks: false, samples: samples))
        await service.setEverything([try activityFixture(id: "a1", date: "2026-10-26")])
        await store.loadAllRuns()
        let details = RunDetailsStore(inbox: store, heart: nil, expectsSamples: true)
        #expect(details.loading)
        await details.open(activityId: "a1")
        #expect(!details.loading)
        #expect(!details.splits.isEmpty)
        #expect(details.weather?.text == "Cloudy · 12°C · 70% humidity")
    }

    @Test func detailsStopLoadingWhenHealthHasNothing() async throws {
        let (store, service, _, _) = try await make(health: FakeHealth(asks: true))
        await service.setEverything([try activityFixture(id: "a1", date: "2026-10-26")])
        await store.loadAllRuns()
        let details = RunDetailsStore(inbox: store, heart: nil, expectsSamples: true)
        await details.open(activityId: "a1")
        #expect(!details.loading)
        #expect(details.splits.isEmpty)
        #expect(details.weather == nil)
    }

    @Test func onlyAHealthRunOnADeviceWithHealthStartsWithASkeleton() throws {
        let health = try activityFixture(id: "a1", date: "2026-10-26")
        #expect(RunDetailsStore.expectsSamples(health, healthAvailable: true))
        #expect(!RunDetailsStore.expectsSamples(health, healthAvailable: false))
        let walk = try activityFixture(id: "a2", date: "2026-10-26", type: "walking")
        #expect(!RunDetailsStore.expectsSamples(walk, healthAvailable: true))
    }

    @Test func backfillNeverAsksForAccess()async throws {
        let (store, service, _, _) = try await make(health: FakeHealth(asks: true, byId: ["hk-a1": workout("hk-a1")]))
        await service.setEverything([try activityFixture(id: "a1", date: "2026-10-26", heartRate: nil)])
        await store.loadAllRuns()
        await store.backfill(activityId: "a1")
        #expect(await service.uploads.isEmpty)
    }

    // Issue #134: the inbox list leaves out extra runs, so the picker must read the full run list.
    @Test func matchCandidatesComeFromEveryRunNotOnlyTheInbox() async throws {
        let (store, service, plans, mondayId) = try await make(activities: [])
        let monday = try #require(plans.plan?.value2.sessions.first { $0.value1.id == mondayId })
        await service.setEverything([try activityFixture(id: "oct31", date: "2026-10-27", disposition: "extra")])
        await store.openSessionPage()
        #expect(store.activities.isEmpty)
        #expect(store.matchCandidates(for: monday).map(\.value2.id) == ["oct31"])
    }

    @Test func aManualRunIsUploadedOnceItsDateIsNotInTheFuture() async throws {
        let (store, service, _, _) = try await make()
        #expect(await store.addManual(id: "m-1", localDate: "2026-10-26", distanceKm: 5, minutes: 30))
        #expect(await service.uploads == [["m-1"]])
        #expect(await store.addManual(id: "m-2", localDate: "2026-12-01", distanceKm: 5, minutes: 30) == false)
        #expect(store.error != nil)
        #expect(await service.uploads.count == 1)
    }

    @Test func movingAMatchedRunReloadsThePlanSoTheOldSessionIsPlannedAgain() async throws {
        let (store, service, plans, mondayId) = try await make()
        let otherId = try #require(plans.plan?.value2.sessions.first { $0.value1.id != mondayId && $0.value2._type == .easy }).value1.id
        await service.setEverything([try activityFixture(id: "a1", date: "2026-10-26", matchedSession: otherId, disposition: "matched")])
        await store.loadAllRuns()
        #expect(store.allRuns.count == 1)

        await store.rematch(activityId: "a1", sessionId: mondayId, label: "Easy run")

        #expect(await service.confirmed.map(\.session) == [mondayId])
        #expect(store.lastConfirmed == nil)
        // The fake loader serves the stored plan again, where Monday is planned: the plan was reloaded, not only patched.
        let monday = try #require(plans.plan?.value2.sessions.first { $0.value1.id == mondayId })
        #expect(monday.value2.status == .planned)
    }

    @Test func unmatchingASessionCallsDeleteAndRefreshesTheLists() async throws {
        let (store, service, _, mondayId) = try await make()
        await store.loadAllRuns()
        await store.unmatch(sessionId: mondayId)
        #expect(await service.unmatched == [mondayId])
        #expect(store.error == nil)
    }

    @Test func anExtraRunGoesBackToTheInbox() async throws {
        let (store, service, _, _) = try await make()
        await store.backToInbox("a1")
        #expect(await service.dispositions == ["a1": "inbox"])
    }

    @Test func aFailureBecomesASentenceAndKeepsTheList() async throws {
        let (store, service, _, _) = try await make()
        await store.refresh()
        await service.fail(.offline)
        await store.refresh()
        #expect(store.error?.contains("connection") == true)
        #expect(store.count == 1)
    }
}
