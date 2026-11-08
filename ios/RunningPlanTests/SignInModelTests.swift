import Foundation
import Testing
@testable import RunningPlan

private actor Account: SignInService {
    var isSignedIn = false
    private(set) var started: [String] = []
    private(set) var verified: [(String, String)] = []
    var verifyError: SignInError?
    private var gate: CheckedContinuation<Void, Never>?
    var gated = false

    func startEmailSignIn(email: String) async throws {
        started.append(email)
        if gated { await withCheckedContinuation { gate = $0 } }
    }

    func verify(email: String, code: String) async throws {
        verified.append((email, code))
        if let verifyError { throw verifyError }
        isSignedIn = true
    }

    func failVerify(_ error: SignInError) { verifyError = error }
    func holdStart() { gated = true }
    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
private final class Landed {
    var count = 0
}

/// Plain sign-in (no save): the account's own plan comes back, nothing is created.
@MainActor
struct SignInModelTests {
    private func make(_ account: Account, _ landed: Landed) -> SignInModel {
        SignInModel(signIn: account, onSignedIn: { landed.count += 1 })
    }

    @Test func startsIdleAndBeginAsksForAnEmail() {
        let model = make(Account(), Landed())
        #expect(model.step == .idle)
        #expect(!model.isPresented)
        model.begin()
        #expect(model.step == .email)
        #expect(model.isPresented)
    }

    @Test func anEmailThenACodeSignsInAndReloadsOnce() async {
        let account = Account()
        let landed = Landed()
        let model = make(account, landed)
        model.begin()

        await model.sendCode(email: "  Runner@Example.com ")
        #expect(model.step == .code(email: "runner@example.com"))
        #expect(model.codeSentTo == "runner@example.com")
        #expect(await account.started == ["runner@example.com"])

        await model.verify(code: " 123 456 ")
        #expect(await account.verified.map(\.1) == ["123456"])
        #expect(model.step == .done)
        #expect(!model.isPresented)
        #expect(landed.count == 1)
    }

    @Test func aWrongCodeStaysOnTheCodeStepWithAMessageAndReloadsNothing() async {
        let account = Account()
        await account.failVerify(.wrongCode)
        let landed = Landed()
        let model = make(account, landed)
        model.begin()
        await model.sendCode(email: "runner@example.com")

        await model.verify(code: "000000")

        #expect(model.step == .code(email: "runner@example.com"))
        #expect(model.error?.contains("code") == true)
        #expect(landed.count == 0)
    }

    @Test func aMalformedEmailIsCaughtBeforeAnyRequest() async {
        let account = Account()
        let model = make(account, Landed())
        model.begin()
        await model.sendCode(email: "not an email")
        #expect(model.step == .email)
        #expect(model.error != nil)
        #expect(await account.started.isEmpty)
    }

    @Test func useADifferentEmailAndCancelGoBack() async {
        let model = make(Account(), Landed())
        model.begin()
        await model.sendCode(email: "runner@example.com")
        model.useDifferentEmail()
        #expect(model.step == .email)
        model.cancelSignIn()
        #expect(model.step == .idle)
        #expect(!model.isPresented)
    }

    @Test func aCodeRequestAnsweredAfterCancelChangesNothing() async {
        let account = Account()
        await account.holdStart()
        let model = make(account, Landed())
        model.begin()
        let pending = Task { await model.sendCode(email: "runner@example.com") }
        while await account.started.isEmpty { await Task.yield() }

        model.cancelSignIn()
        await account.release()
        await pending.value

        #expect(model.step == .idle)
    }
}
