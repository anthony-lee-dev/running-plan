import APIClient
import Foundation
import Testing
@testable import RunningPlan

private actor FakeSignIn: SignInService {
    var isSignedIn: Bool
    private(set) var started: [String] = []
    private(set) var verified: [(String, String)] = []
    var startError: SignInError?
    var verifyError: SignInError?

    init(signedIn: Bool) { isSignedIn = signedIn }

    func startEmailSignIn(email: String) async throws {
        started.append(email)
        if let startError { throw startError }
    }

    func verify(email: String, code: String) async throws {
        verified.append((email, code))
        if let verifyError { throw verifyError }
        isSignedIn = true
    }

    func failStart(_ error: SignInError) { startError = error }
    func failVerify(_ error: SignInError) { verifyError = error }
    func signOut() { isSignedIn = false }
}

/// Each call waits until `release()`, so a test can act while a request is in flight.
private actor GatedSignIn: SignInService {
    var isSignedIn = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    func startEmailSignIn(email: String) async throws { await wait() }
    func verify(email: String, code: String) async throws {
        await wait()
        isSignedIn = true
    }

    private func wait() async {
        calls += 1
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private actor FakeSaver: PlanSaving {
    private(set) var saved: [SavedPreview] = []
    private var results: [Result<String, SaveError>]

    init(_ results: [Result<String, SaveError>] = []) { self.results = results }

    func save(_ preview: SavedPreview) async throws -> String {
        saved.append(preview)
        if !results.isEmpty { return try results.removeFirst().get() }
        return preview.ids.plan
    }
}

private final class MemoryStore: PreviewDraftStoring {
    var saved: SavedPreview?
    init(_ preview: SavedPreview?) { saved = preview }
    func save(_ preview: SavedPreview) { saved = preview }
    func load(now: Date) -> SavedPreview? { saved }
    func clear() { saved = nil }
}

@MainActor
struct SaveFlowModelTests {
    private func preview() throws -> SavedPreview {
        var answers = InterviewAnswers()
        answers.goal.distance = .tenK
        return SavedPreview(answers: answers, draft: try DraftFixture.draft(), savedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func signedInSavesStraightAwayAndClearsTheDraft() async throws {
        let p = try preview()
        let saver = FakeSaver()
        let store = MemoryStore(p)
        let model = SaveFlowModel(signIn: FakeSignIn(signedIn: true), saver: saver, store: store)

        await model.save(p)

        #expect(model.step == .saved(planId: p.ids.plan))
        #expect(await saver.saved.map(\.ids) == [p.ids])
        #expect(store.saved == nil, "a saved plan must not reopen as a preview")
    }

    @Test func signedOutAsksForAnEmailThenACodeThenSaves() async throws {
        let p = try preview()
        let signIn = FakeSignIn(signedIn: false)
        let saver = FakeSaver()
        let model = SaveFlowModel(signIn: signIn, saver: saver, store: MemoryStore(p))

        await model.save(p)
        #expect(model.step == .email)
        #expect(model.showsSignIn)

        await model.sendCode(email: "  Runner@Example.com ")
        #expect(model.step == .code(email: "runner@example.com"))
        #expect(await signIn.started == ["runner@example.com"])

        await model.verify(code: " 123 456 ")
        #expect(await signIn.verified.map(\.1) == ["123456"])
        #expect(model.step == .saved(planId: p.ids.plan))
        #expect(!model.showsSignIn)
    }

    @Test func tokensTheServerNoLongerAcceptsLeadToSignInWithoutAnError() async throws {
        // Stored tokens can outlive their refresh family (or the local test server); saving then asks to sign in.
        let p = try preview()
        let saver = FakeSaver([.failure(.signedOut), .success(p.ids.plan)])
        let model = SaveFlowModel(signIn: FakeSignIn(signedIn: true), saver: saver, store: MemoryStore(p))

        await model.save(p)
        #expect(model.step == .email)
        #expect(model.error == nil)

        await model.sendCode(email: "runner@example.com")
        await model.verify(code: "123456")
        #expect(model.step == .saved(planId: p.ids.plan))
        #expect(await saver.saved.map(\.ids) == [p.ids, p.ids], "a retry sends the same ids")
    }

    @Test func aWrongCodeStaysOnTheCodeStepWithAMessage() async throws {
        let signIn = FakeSignIn(signedIn: false)
        await signIn.failVerify(.wrongCode)
        let saver = FakeSaver()
        let model = SaveFlowModel(signIn: signIn, saver: saver, store: MemoryStore(nil))

        await model.save(try preview())
        await model.sendCode(email: "runner@example.com")
        await model.verify(code: "000000")

        #expect(model.step == .code(email: "runner@example.com"))
        #expect(model.error?.contains("code") == true)
        #expect(await saver.saved.isEmpty)
    }

    @Test func aMalformedEmailIsCaughtBeforeAnyRequest() async throws {
        let signIn = FakeSignIn(signedIn: false)
        let model = SaveFlowModel(signIn: signIn, saver: FakeSaver(), store: MemoryStore(nil))
        await model.save(try preview())

        await model.sendCode(email: "not an email")

        #expect(model.step == .email)
        #expect(model.error != nil)
        #expect(await signIn.started.isEmpty)
    }

    @Test func aSaveFailureKeepsTheDraftAndExplains() async throws {
        let p = try preview()
        let store = MemoryStore(p)
        let model = SaveFlowModel(signIn: FakeSignIn(signedIn: true), saver: FakeSaver([.failure(.offline)]), store: store)

        await model.save(p)

        #expect(model.step == .idle)
        #expect(model.error?.contains("connection") == true)
        #expect(store.saved == p)
    }

    @Test func changingTheEmailAndCancellingGoBack() async throws {
        let model = SaveFlowModel(signIn: FakeSignIn(signedIn: false), saver: FakeSaver(), store: MemoryStore(nil))
        await model.save(try preview())
        await model.sendCode(email: "runner@example.com")

        model.useDifferentEmail()
        #expect(model.step == .email)

        model.cancelSignIn()
        #expect(model.step == .idle)
        #expect(!model.showsSignIn)
    }

    @Test func cancellingWhileTheCodeIsCheckedSavesNothing() async throws {
        let signIn = GatedSignIn()
        let saver = FakeSaver()
        let model = SaveFlowModel(signIn: signIn, saver: saver, store: MemoryStore(nil))
        await model.save(try preview())
        let sent = Task { await model.sendCode(email: "runner@example.com") }
        while await signIn.calls < 1 { await Task.yield() }
        await signIn.release()
        await sent.value

        let verifying = Task { await model.verify(code: "123456") }
        while await signIn.calls < 2 { await Task.yield() }
        model.cancelSignIn()
        await signIn.release()
        await verifying.value

        #expect(model.step == .idle)
        #expect(await saver.saved.isEmpty, "the user cancelled: no plan may be saved")
    }

    @Test func cancellingWhileTheCodeIsSentDoesNotReopenSignIn() async throws {
        let signIn = GatedSignIn()
        let model = SaveFlowModel(signIn: signIn, saver: FakeSaver(), store: MemoryStore(nil))
        await model.save(try preview())

        let sending = Task { await model.sendCode(email: "runner@example.com") }
        while await signIn.calls < 1 { await Task.yield() }
        model.cancelSignIn()
        await signIn.release()
        await sending.value

        #expect(model.step == .idle)
        #expect(!model.showsSignIn)
    }

    @Test func aSaveClearsOnlyTheDraftItSaved() async throws {
        let p = try preview()
        let newer = try preview()
        let store = MemoryStore(newer)
        let model = SaveFlowModel(signIn: FakeSignIn(signedIn: true), saver: FakeSaver(), store: store)

        await model.save(p)

        #expect(store.saved == newer)
    }

    @Test func aDraftOlderThanADayIsNotSaved() async throws {
        let p = try preview()
        let saver = FakeSaver()
        let model = SaveFlowModel(
            signIn: FakeSignIn(signedIn: true), saver: saver, store: MemoryStore(p),
            now: { p.savedAt.addingTimeInterval(PreviewDraftStore.lifetime + 1) }
        )

        await model.save(p)

        #expect(model.step == .idle)
        #expect(model.error?.contains("more than a day old") == true)
        #expect(await saver.saved.isEmpty)
    }

    @Test func tooManyTriesIsExplained() async throws {
        let signIn = FakeSignIn(signedIn: false)
        await signIn.failStart(.tooManyRequests)
        let model = SaveFlowModel(signIn: signIn, saver: FakeSaver(), store: MemoryStore(nil))
        await model.save(try preview())

        await model.sendCode(email: "runner@example.com")

        #expect(model.step == .email)
        #expect(model.error?.contains("Too many") == true)
    }
}
