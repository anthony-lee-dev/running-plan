import Foundation
import Observation

/// What saving needs from the account: whether there is one, and email sign-in.
protocol SignInService: Sendable {
    var isSignedIn: Bool { get async }
    func startEmailSignIn(email: String) async throws
    func verify(email: String, code: String) async throws
}

extension AuthSession: SignInService {}

/// Save on DK-Preview: signs in with an emailed code when needed, then creates the plan from the stored draft.
@MainActor
@Observable
final class SaveFlowModel {
    enum Step: Equatable {
        case idle
        case email
        case code(email: String)
        case saving
        case saved(planId: String)
    }

    private(set) var step: Step = .idle
    private(set) var error: String?
    /// A sign-in request is in flight.
    private(set) var busy = false

    private let signIn: SignInService
    private let saver: PlanSaving
    private let store: PreviewDraftStoring
    private var pending: SavedPreview?

    init(signIn: SignInService, saver: PlanSaving, store: PreviewDraftStoring) {
        self.signIn = signIn
        self.saver = saver
        self.store = store
    }

    var showsSignIn: Bool {
        switch step {
        case .email, .code: true
        default: false
        }
    }

    func save(_ preview: SavedPreview) async {
        pending = preview
        error = nil
        if await signIn.isSignedIn {
            await attemptSave()
        } else {
            step = .email
        }
    }

    func sendCode(email raw: String) async {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeEmail(email) else {
            error = "Enter an email address like name@example.com."
            return
        }
        await run {
            try await self.signIn.startEmailSignIn(email: email)
            self.step = .code(email: email)
        }
    }

    func verify(code raw: String) async {
        guard case .code(let email) = step else { return }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        await run { try await self.signIn.verify(email: email, code: code) }
        if error == nil { await attemptSave() }
    }

    func useDifferentEmail() {
        error = nil
        step = .email
    }

    func cancelSignIn() {
        error = nil
        step = .idle
    }

    private func attemptSave() async {
        guard let pending else { return }
        step = .saving
        do {
            let id = try await saver.save(pending)
            store.clear()
            step = .saved(planId: id)
        } catch SaveError.signedOut {
            // Tokens the server no longer accepts: sign in again, then the same save is retried.
            step = .email
        } catch {
            step = .idle
            self.error = Self.message(for: error)
        }
    }

    private func run(_ body: () async throws -> Void) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await body()
        } catch {
            self.error = Self.message(for: error)
        }
    }

    private static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ") && text.count <= 254
    }

    static func message(for error: Error) -> String {
        switch error {
        case SignInError.invalidEmail: "That email address doesn't look right."
        case SignInError.wrongCode: "That code didn't work. Check the latest email and try again."
        case SignInError.tooManyRequests: "Too many tries just now. Please wait a little and try again."
        case SignInError.offline, SaveError.offline: "We couldn't reach the server. Check your connection and try again."
        case SaveError.conflict: "This plan clashes with one already saved. Change an answer to make a new one."
        default: "Something went wrong saving your plan. Please try again."
        }
    }
}
