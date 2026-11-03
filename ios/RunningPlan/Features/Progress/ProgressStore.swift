import APIClient
import Foundation
import Observation

protocol ProgressLoading: Sendable {
    /// The plan's progress on the user's local day, or nil when the plan is gone.
    func progress(planId: String, today: String) async throws -> Components.Schemas.Progress?
}

/// `GET /v1/plans/{id}/progress` through a client that carries the user's token (`AuthMiddleware`).
struct APIProgressLoader: ProgressLoading {
    let client: Client

    func progress(planId: String, today: String) async throws -> Components.Schemas.Progress? {
        let output: Operations.getProgress.Output
        do {
            output = try await client.getProgress(path: .init(planId: planId), query: .init(today: today))
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            throw underlying is URLError || (underlying as? SignInError) == .offline ? PlanLoadError.offline : PlanLoadError.server
        }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .notFound: return nil
        case .unauthorized: throw PlanLoadError.signedOut
        case .undocumented: throw PlanLoadError.server
        }
    }
}

/// The Progress tab's data. Loaded when the tab shows and again when the plan changes; a refresh that fails keeps what
/// was shown (it is read-only, and the next refresh catches up).
@MainActor
@Observable
final class ProgressStore {
    enum State: Equatable {
        case loading
        case loaded(Components.Schemas.Progress)
        case failed(String)
    }

    private(set) var state: State = .loading
    private let loader: ProgressLoading

    init(loader: ProgressLoading) {
        self.loader = loader
    }

    func load(planId: String, today: String) async {
        let shown: Components.Schemas.Progress? = if case .loaded(let progress) = state, progress.planId == planId { progress } else { nil }
        if shown == nil { state = .loading }
        do {
            if let progress = try await loader.progress(planId: planId, today: today) {
                state = .loaded(progress)
            } else {
                state = .failed("This plan is no longer available. Try again to load your latest plan.")
            }
        } catch is CancellationError {
            return
        } catch {
            if shown != nil { return }
            state = switch error {
            case PlanLoadError.offline: .failed("We couldn't reach the server. Check your connection and try again.")
            case PlanLoadError.signedOut: .failed("You've been signed out. Sign in again to see your progress.")
            default: .failed("Something went wrong loading your progress. Please try again.")
            }
        }
    }
}
