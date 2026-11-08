import Foundation
import Observation

/// What `SignInView` needs from a model: the address the code went to (nil while asking for the email), the last error,
/// whether a request is in flight, and the actions. `SaveFlowModel` (sign in to save) and `SignInModel` (plain sign-in) both fit.
@MainActor
protocol SignInFlowing: AnyObject {
    var codeSentTo: String? { get }
    var error: String? { get }
    var busy: Bool { get }
    func sendCode(email: String) async
    func verify(code: String) async
    func useDifferentEmail()
    func cancelSignIn()
}

/// Plain sign-in, with nothing to save: "Sign in" on the signed-out screens and on the "Sign in again" messages.
/// Once the code is accepted it calls `onSignedIn`, which loads the account's own plan; it never creates one.
@MainActor
@Observable
final class SignInModel: SignInFlowing {
    enum Step: Equatable {
        case idle
        case email
        case code(email: String)
        case done
    }

    private(set) var step: Step = .idle
    private(set) var error: String?
    private(set) var busy = false

    private let signIn: SignInService
    private let onSignedIn: () async -> Void
    /// Moves on cancel and "use a different email", so the answer to a request made before then changes nothing.
    private var attempt = 0

    init(signIn: SignInService, onSignedIn: @escaping () async -> Void) {
        self.signIn = signIn
        self.onSignedIn = onSignedIn
    }

    /// The sheet is up while asking for the email or the code.
    var isPresented: Bool {
        switch step {
        case .email, .code: true
        case .idle, .done: false
        }
    }

    var codeSentTo: String? {
        if case .code(let email) = step { return email }
        return nil
    }

    /// Always asks, even when tokens are still stored: the person chose to sign in.
    func begin() {
        attempt += 1
        error = nil
        step = .email
    }

    func sendCode(email raw: String) async {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard SaveFlowModel.looksLikeEmail(email) else {
            error = "Enter an email address like name@example.com."
            return
        }
        let mine = attempt
        guard await run({ try await self.signIn.startEmailSignIn(email: email) }), mine == attempt else { return }
        step = .code(email: email)
    }

    func verify(code raw: String) async {
        guard case .code(let email) = step else { return }
        let code = raw.filter(\.isNumber) // a pasted "123 456" has a space
        let mine = attempt
        guard await run({ try await self.signIn.verify(email: email, code: code) }), mine == attempt else { return }
        step = .done
        await onSignedIn()
    }

    func useDifferentEmail() {
        attempt += 1
        error = nil
        step = .email
    }

    func cancelSignIn() {
        attempt += 1
        error = nil
        step = .idle
    }

    /// Runs a sign-in request; true when it succeeded.
    private func run(_ body: () async throws -> Void) async -> Bool {
        busy = true
        error = nil
        defer { busy = false }
        let mine = attempt
        do {
            try await body()
            return true
        } catch {
            if mine == attempt { self.error = Self.message(for: error) }
            return false
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case SignInError.invalidEmail: "That email address doesn't look right."
        case SignInError.wrongCode: "That code didn't work. Check the latest email and try again."
        case SignInError.tooManyRequests: "Too many tries just now. Please wait a little and try again."
        case SignInError.offline: "We couldn't reach the server. Check your connection and try again."
        default: "Something went wrong signing in. Please try again."
        }
    }
}
