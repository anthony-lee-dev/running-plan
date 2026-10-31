import APIClient
import Foundation

enum PlanLoadError: Error, Equatable {
    /// The server refused the tokens even after a refresh.
    case signedOut
    case offline
    case server
}

protocol PlanLoading: Sendable {
    /// The plan the app shows, or nil when there is none.
    func activePlan() async throws -> Components.Schemas.PlanDetail?
    /// A plan by id, or nil when it is gone.
    func plan(id: String) async throws -> Components.Schemas.PlanDetail?
}

/// Reads plans through a client that carries the user's token (`AuthMiddleware`).
struct APIPlanLoader: PlanLoading {
    let client: Client

    /// The most recently updated plan on the first page. The list is ordered by start date then id, not by when a plan
    /// was saved, so the latest save (the one the user just made) is picked by `updatedAt`.
    func activePlan() async throws -> Components.Schemas.PlanDetail? {
        let output = try await call { try await client.listPlans(query: .init(limit: 50)) }
        let plans: [Components.Schemas.PlanSummary]
        switch output {
        case .ok(let ok): plans = try ok.body.json.plans
        case .unauthorized: throw PlanLoadError.signedOut
        case .undocumented: throw PlanLoadError.server
        }
        guard let latest = plans.filter({ $0.value1.deletedAt == nil }).max(by: { $0.value1.updatedAt < $1.value1.updatedAt }) else { return nil }
        return try await plan(id: latest.value1.id)
    }

    func plan(id: String) async throws -> Components.Schemas.PlanDetail? {
        let output = try await call { try await client.getPlan(path: .init(planId: id)) }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .notFound: return nil
        case .unauthorized: throw PlanLoadError.signedOut
        case .undocumented: throw PlanLoadError.server
        }
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            // No network, here or in the middleware's token refresh, is an offline problem; anything else the server's.
            throw underlying is URLError || (underlying as? SignInError) == .offline ? PlanLoadError.offline : PlanLoadError.server
        }
    }
}
