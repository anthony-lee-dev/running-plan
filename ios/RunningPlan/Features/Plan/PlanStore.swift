import APIClient
import Foundation
import Observation

/// The saved plan the Next and Plan tabs show. Loaded from the server on launch and after a save; kept in memory only
/// (the on-device store and offline sync are slice 5).
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

    init(loader: PlanLoading, account: SignInService) {
        self.loader = loader
        self.account = account
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
}
