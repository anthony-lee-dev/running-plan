import APIClient
import Foundation
import Observation

/// The saved plan the Next and Plan tabs show. Loaded from the server on launch and after a save; kept in memory only
/// (the on-device store and offline sync are slice 5). Session edits go straight to the API, and the server's copy of
/// the session replaces ours, so the next edit sends the new revision.
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

    init(loader: PlanLoading, account: SignInService, writer: SessionWriting) {
        self.loader = loader
        self.account = account
        self.writer = writer
    }

    var plan: Components.Schemas.PlanDetail? {
        if case .loaded(let plan) = state { return plan }
        return nil
    }

    func load() async {
        guard await account.isSignedIn else {
            state = .empty
            return
        }
        await run { try await self.loader.activePlan() }
    }

    /// After a save: show that plan without searching for it.
    func show(planId: String) async {
        await run { try await self.loader.plan(id: planId) }
    }

    private func run(_ fetch: () async throws -> Components.Schemas.PlanDetail?) async {
        if plan == nil { state = .loading }
        do {
            state = try await fetch().map(State.loaded) ?? .empty
        } catch PlanLoadError.signedOut {
            state = .empty
        } catch is CancellationError {
            return
        } catch PlanLoadError.offline {
            state = .failed("We couldn't reach the server. Check your connection and try again.")
        } catch {
            state = .failed("Something went wrong loading your plan. Please try again.")
        }
    }

    // MARK: Edits

    /// Sends the edits in order. Returns a sentence for the screen when one fails (the ones before it stay applied).
    func apply(_ edits: [SessionEdit]) async -> String? {
        for edit in edits {
            if let error = await write({ try await self.writer.update(id: edit.sessionId, revision: edit.revision, edit.update) }) { return error }
        }
        return nil
    }

    func create(_ session: Components.Schemas.SessionCreate) async -> String? {
        guard let planId = plan?.value1.value1.id else { return "Your plan isn't loaded yet. Please try again." }
        return await write { try await self.writer.create(planId: planId, session) }
    }

    func delete(sessionId: String, revision: Int) async -> String? {
        await write { try await self.writer.delete(id: sessionId, revision: revision) }
    }

    func checkIn(sessionId: String, feeling: BeforeFeeling) async -> String? {
        do {
            try await writer.checkIn(sessionId: sessionId, feeling: feeling, id: UUID().uuidString.lowercased())
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    private func write(_ body: () async throws -> Components.Schemas.SessionWriteResult) async -> String? {
        do {
            merge(try await body())
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
        state = .loaded(detail)
    }
}
