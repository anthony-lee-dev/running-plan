import APIClient
import Foundation

enum GoalSettingsError: Error, Equatable {
    case signedOut
    /// 404: the plan is gone.
    case notFound
    /// 409: the plan changed since we loaded it.
    case conflict
    /// 400: the API refused the values.
    case invalid
    /// 429 on the export.
    case rateLimited
    case offline
    case server
}

/// What Goal and settings needs besides the review setting and proposals: the profile (to prefill the interview), the
/// goal edit, the data export and account deletion.
protocol GoalSettingsServing: Sendable {
    func profile() async throws -> Components.Schemas.Profile
    func updateGoal(planId: String, revision: Int, goal: Components.Schemas.Goal) async throws -> Components.Schemas.PlanDetail
    /// Everything the server stores for the account, as pretty-printed JSON.
    func exportAccount() async throws -> Data
    func deleteAccount() async throws
}

/// Calls the endpoints through a client that carries the user's token (`AuthMiddleware`).
struct APIGoalSettingsService: GoalSettingsServing {
    let client: Client

    func profile() async throws -> Components.Schemas.Profile {
        let output = try await call { try await client.getProfile() }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw GoalSettingsError.signedOut
        case .undocumented: throw GoalSettingsError.server
        }
    }

    func updateGoal(planId: String, revision: Int, goal: Components.Schemas.Goal) async throws -> Components.Schemas.PlanDetail {
        let output = try await call {
            try await client.updatePlan(path: .init(planId: planId), headers: .init(If_hyphen_Match: "\"\(revision)\""), body: .json(.init(goal: goal)))
        }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .badRequest: throw GoalSettingsError.invalid
        case .unauthorized: throw GoalSettingsError.signedOut
        case .notFound: throw GoalSettingsError.notFound
        case .conflict: throw GoalSettingsError.conflict
        case .undocumented: throw GoalSettingsError.server
        }
    }

    func exportAccount() async throws -> Data {
        let output = try await call { try await client.exportAccount() }
        switch output {
        case .ok(let ok): return try Self.encode(try ok.body.json)
        case .unauthorized: throw GoalSettingsError.signedOut
        case .tooManyRequests: throw GoalSettingsError.rateLimited
        case .undocumented: throw GoalSettingsError.server
        }
    }

    func deleteAccount() async throws {
        let output = try await call { try await client.deleteAccount() }
        switch output {
        case .noContent: return
        case .unauthorized: throw GoalSettingsError.signedOut
        case .undocumented: throw GoalSettingsError.server
        }
    }

    /// The export as the spec's JSON (dates written the way the server writes them).
    static func encode(_ export: Components.Schemas.AccountExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(try APIConfiguration.dateTranscoder.encode(date))
        }
        return try encoder.encode(export)
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            throw underlying is URLError || (underlying as? SignInError) == .offline ? GoalSettingsError.offline : GoalSettingsError.server
        }
    }
}
