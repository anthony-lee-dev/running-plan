import APIClient
import Foundation
import Observation

/// What saving needs from the account: whether there is one, and email sign-in.
protocol SignInService: Sendable {
    var isSignedIn: Bool { get async }
    func startEmailSignIn(email: String) async throws
    func verify(email: String, code: String) async throws
}

extension AuthSession: SignInService {}

/// Save on DK-Preview: signs in with an emailed code when needed, then creates the plan from the stored draft. The
/// same flow saves a blank plan ("I'd rather build my own plan").
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
    private let now: () -> Date
    private enum Pending {
        case preview(SavedPreview)
        case blank(Components.Schemas.PlanCreate)
    }

    private var pending: Pending?
    /// Moves on cancel and "use a different email", so the answer to a request made before then changes nothing.
    private var attempt = 0

    init(signIn: SignInService, saver: PlanSaving, store: PreviewDraftStoring, now: @escaping () -> Date = Date.init) {
        self.signIn = signIn
        self.saver = saver
        self.store = store
        self.now = now
    }

    var showsSignIn: Bool {
        switch step {
        case .email, .code: true
        default: false
        }
    }

    func save(_ preview: SavedPreview) async {
        error = nil
        // The plan would start from a stale date; the 24-hour rule (design §7) applies to saving too.
        guard now().timeIntervalSince(preview.savedAt) < PreviewDraftStore.lifetime else {
            error = "This preview is more than a day old. Change an answer to make a fresh one."
            return
        }
        await begin(.preview(preview))
    }

    /// Signs in when needed, then creates the blank plan. The preview draft, if any, is left alone.
    func saveBlank(_ plan: Components.Schemas.PlanCreate) async {
        error = nil
        await begin(.blank(plan))
    }

    private func begin(_ next: Pending) async {
        pending = next
        attempt += 1
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
        let mine = attempt
        guard await run({ try await self.signIn.startEmailSignIn(email: email) }), mine == attempt else { return }
        step = .code(email: email)
    }

    func verify(code raw: String) async {
        guard case .code(let email) = step else { return }
        let code = raw.filter(\.isNumber) // a pasted "123 456" has a space
        let mine = attempt
        guard await run({ try await self.signIn.verify(email: email, code: code) }), mine == attempt else { return }
        await attemptSave()
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

    private func attemptSave() async {
        guard let pending else { return }
        step = .saving
        do {
            let id: String
            switch pending {
            case .preview(let preview):
                id = try await saver.save(preview)
                // Only the draft that was saved: a newer one made meanwhile stays.
                if store.load(now: now())?.ids == preview.ids { store.clear() }
            case .blank(let plan):
                id = try await saver.createBlank(plan)
            }
            step = .saved(planId: id)
        } catch SaveError.signedOut {
            // Tokens the server no longer accepts: sign in again, then the same save is retried.
            step = .email
        } catch {
            step = .idle
            self.error = Self.message(for: error)
        }
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
        case SignInError.server: "Something went wrong signing in. Please try again."
        default: "Something went wrong saving your plan. Please try again."
        }
    }
}
