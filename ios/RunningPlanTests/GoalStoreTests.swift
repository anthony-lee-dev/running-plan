import APIClient
import Foundation
import Testing
@testable import RunningPlan

private actor FakeGoalService: GoalSettingsServing {
    private(set) var calls: [String] = []
    private(set) var goals: [Components.Schemas.Goal] = []
    var profileResult: Result<Components.Schemas.Profile, GoalSettingsError> = .failure(.server)
    var goalResult: Result<Components.Schemas.PlanDetail, GoalSettingsError> = .failure(.server)
    var exportResult: Result<Data, GoalSettingsError> = .success(Data(#"{"plans":[]}"#.utf8))
    var deleteError: GoalSettingsError?

    func set(profile: Result<Components.Schemas.Profile, GoalSettingsError>) { profileResult = profile }
    func set(goal: Result<Components.Schemas.PlanDetail, GoalSettingsError>) { goalResult = goal }
    func set(export: Result<Data, GoalSettingsError>) { exportResult = export }
    func set(deleteError: GoalSettingsError?) { self.deleteError = deleteError }

    func profile() async throws -> Components.Schemas.Profile {
        calls.append("profile")
        return try profileResult.get()
    }

    func updateGoal(planId: String, revision: Int, goal: Components.Schemas.Goal) async throws -> Components.Schemas.PlanDetail {
        calls.append("updateGoal \(revision)")
        goals.append(goal)
        return try goalResult.get()
    }

    func exportAccount() async throws -> Data {
        calls.append("export")
        return try exportResult.get()
    }

    func deleteAccount() async throws {
        calls.append("delete")
        if let deleteError { throw deleteError }
    }
}

/// Signed in until `signOut`, like the real session.
private actor Session: SignInService {
    private(set) var signedIn = true
    private(set) var signOuts = 0
    var isSignedIn: Bool { signedIn }
    func startEmailSignIn(email: String) async throws {}
    func verify(email: String, code: String) async throws {}
    func signOut() { signedIn = false; signOuts += 1 }
}

private actor Loader: PlanLoading {
    private(set) var calls: [String] = []
    func activePlan() async throws -> Components.Schemas.PlanDetail? { try PlanFixture.detail() }
    func plan(id: String) async throws -> Components.Schemas.PlanDetail? {
        calls.append("plan \(id)")
        return try PlanFixture.detail()
    }
}

private actor Reviews: ReviewServing {
    private(set) var calls: [String] = []
    var made: [Components.Schemas.Proposal] = []
    var error: ReviewError?
    func set(made: [Components.Schemas.Proposal], error: ReviewError? = nil) { self.made = made; self.error = error }

    func review(planId: String, weekIndex: Int, today: String) async throws -> Components.Schemas.WeeklyReview? { nil }
    func generate(planId: String, today: String, interview: Components.Schemas.InterviewAnswers?) async throws -> [Components.Schemas.Proposal] {
        calls.append(interview == nil ? "generate" : "generate interview")
        if let error { throw error }
        return made
    }
    func pending(planId: String) async throws -> [Components.Schemas.Proposal] { [] }
    func accept(id: String, includeUserOwned: Bool) async throws -> Components.Schemas.PlanDetail { throw ReviewError.server }
    func dismiss(id: String) async throws {}
}

@MainActor
private struct Rig {
    let service = FakeGoalService()
    let session = Session()
    let reviews = Reviews()
    let loader = Loader()
    let plans: PlanStore
    let store: GoalStore
    let directory: URL

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("goal-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        plans = PlanStore(loader: loader, account: session, writer: FakeWriter())
        await plans.load()
        let session = self.session
        store = GoalStore(
            service: service, plans: plans, proposals: ProposalsStore(service: reviews, plans: plans),
            signOut: { await session.signOut() }, exportDirectory: directory
        )
    }

    var exportFile: URL { directory.appendingPathComponent("running-plan-export.json") }
}

@MainActor
struct GoalStoreTests {
    // MARK: Goal

    @Test func savingTheGoalSendsThePlanRevisionAndShowsTheServersPlan() async throws {
        let rig = try await Rig()
        var updated = try PlanFixture.detail(goal: #"{"type":"10k","date":"2027-01-10","targetTimeSec":3000}"#)
        updated.value1.value1.revision = 4
        await rig.service.set(goal: .success(updated))

        let saved = await rig.store.editGoal(date: "2027-01-10", targetSeconds: 3000)

        #expect(saved)
        #expect(await rig.service.calls == ["updateGoal 3"])
        #expect(await rig.service.goals == [Components.Schemas.Goal(_type: ._10k, date: "2027-01-10", targetTimeSec: 3000)])
        #expect(rig.plans.plan == updated)
        #expect(rig.store.goalError == nil)
    }

    @Test func aConflictLoadsTheLatestPlanAndSaysSo() async throws {
        let rig = try await Rig()
        await rig.service.set(goal: .failure(.conflict))

        let saved = await rig.store.editGoal(date: nil, targetSeconds: nil)

        #expect(!saved)
        #expect(await rig.loader.calls == ["plan \(PlanFixture.planID)"])
        #expect(rig.store.goalError?.contains("changed somewhere else") == true)
    }

    @Test func aRefusedGoalSaysWhichInputsToChange() async throws {
        let rig = try await Rig()
        await rig.service.set(goal: .failure(.invalid))
        _ = await rig.store.editGoal(date: "2020-01-01", targetSeconds: 3000)
        #expect(rig.store.goalError?.contains("date or time") == true)
    }

    // MARK: Re-running the interview

    @Test func theInterviewIsPrefilledFromTheProfile() async throws {
        let rig = try await Rig()
        await rig.service.set(profile: .success(try ProfileFixture.profile(#""scheduling":{"longRunDay":"sat"}"#, targetDisplay: "effort")))
        let answers = try #require(await rig.store.rerunAnswers(today: PlanFixture.today))
        #expect(answers.goal.distance == .tenK)
        #expect(answers.targetDisplay == .effort)
        #expect(answers.longRunDay == .sat)
    }

    @Test func aProfileThatWillNotLoadStillPrefillsTheGoal() async throws {
        let rig = try await Rig()
        let answers = try #require(await rig.store.rerunAnswers(today: PlanFixture.today))
        #expect(answers.goal.date == "2026-12-13")
        #expect(answers.targetDisplay == nil)
    }

    @Test func aRerunShowsOneProposalAndChangesNothing() async throws {
        let rig = try await Rig()
        let proposal = try ReviewFixture.proposal(kind: "interview_rerun", changes: [ReviewFixture.change(before: 8000, after: 9000)])
        await rig.reviews.set(made: [proposal])

        let shown = await rig.store.rerun(answers: InterviewAnswers(), today: PlanFixture.today)

        #expect(shown)
        #expect(rig.store.proposals.proposals == [proposal])
        #expect(await rig.reviews.calls == ["generate interview"])
        #expect(await rig.service.calls.isEmpty)
    }

    @Test func aRerunTheServerRefusesSaysSo() async throws {
        let rig = try await Rig()
        await rig.reviews.set(made: [], error: .invalid)
        let shown = await rig.store.rerun(answers: InterviewAnswers(), today: PlanFixture.today)
        #expect(!shown)
        #expect(rig.store.goalError?.contains("weeks that are left") == true)
    }

    // MARK: Export

    @Test func exportWritesTheFileAndOffersIt() async throws {
        let rig = try await Rig()
        await rig.store.exportData()
        #expect(rig.store.export == .ready(rig.exportFile))
        #expect(try Data(contentsOf: rig.exportFile) == Data(#"{"plans":[]}"#.utf8))
    }

    @Test func tooManyExportsSaysToWait() async throws {
        let rig = try await Rig()
        await rig.service.set(export: .failure(.rateLimited))
        await rig.store.exportData()
        guard case .failed(let message) = rig.store.export else { Issue.record("expected a failure, got \(rig.store.export)"); return }
        #expect(message.contains("Try again in a little while"))
    }

    @Test func aFailedExportRemovesTheEarlierFile() async throws {
        let rig = try await Rig()
        await rig.store.exportData()
        await rig.service.set(export: .failure(.offline))
        await rig.store.exportData()
        #expect(!FileManager.default.fileExists(atPath: rig.exportFile.path))
        guard case .failed(let message) = rig.store.export else { Issue.record("expected a failure"); return }
        #expect(message.contains("connection"))
    }

    // MARK: Account

    @Test func signingOutClearsTheExportAndShowsTheSignedOutState() async throws {
        let rig = try await Rig()
        await rig.store.exportData()

        await rig.store.signOut()

        #expect(await rig.session.signOuts == 1)
        #expect(rig.plans.state == .empty)
        #expect(rig.store.export == .idle)
        #expect(!FileManager.default.fileExists(atPath: rig.exportFile.path))
    }

    @Test func deletingTheAccountSignsOutAfterTheServerDeletedIt() async throws {
        let rig = try await Rig()
        let deleted = await rig.store.deleteAccount()
        #expect(deleted)
        #expect(await rig.service.calls == ["delete"])
        #expect(await rig.session.signOuts == 1)
        #expect(rig.plans.state == .empty)
    }

    @Test func aFailedDeletionKeepsTheAccountSignedIn() async throws {
        let rig = try await Rig()
        await rig.service.set(deleteError: .offline)
        let deleted = await rig.store.deleteAccount()
        #expect(!deleted)
        #expect(await rig.session.signOuts == 0)
        #expect(rig.plans.plan != nil)
        #expect(rig.store.accountError?.contains("connection") == true)
    }
}
