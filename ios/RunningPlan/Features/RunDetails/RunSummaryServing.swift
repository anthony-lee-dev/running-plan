import APIClient
import Foundation

/// The written summary of a run (issue #132), as the card shows it.
struct RunSummaryResult: Equatable, Sendable {
    let text: String
    /// The next planned session, or the fixed pain guidance when `pain` is true. Written by the server.
    let nextStep: String?
    /// Model text that passed the server's checks (labelled "Generated summary"); otherwise the template.
    let isAI: Bool
    /// True only when the server has no stored text yet and the model has not been asked.
    let canGenerate: Bool
    let pain: Bool
}

enum RunSummaryError: Error, Equatable {
    case signedOut
    case notFound
    /// 429: the per-account limit. The template already shown stays.
    case rateLimited
    case offline
    case server
}

/// The summary endpoints and the account's switch for them (`aiSummaries` on the profile).
protocol RunSummaryServing: Sendable {
    /// Never calls the model.
    func summary(activityId: String, today: String) async throws -> RunSummaryResult
    /// Asks the server to write the AI text (once per change of the run's data).
    func generate(activityId: String, today: String) async throws -> RunSummaryResult
    func aiEnabled() async throws -> Bool
    func setAIEnabled(_ on: Bool) async throws
}

struct APIRunSummaryService: RunSummaryServing {
    let client: Client

    func summary(activityId: String, today: String) async throws -> RunSummaryResult {
        let output = try await call { try await client.getRunSummary(path: .init(activityId: activityId), query: .init(today: today)) }
        switch output {
        case .ok(let ok): return Self.result(try ok.body.json)
        case .unauthorized: throw RunSummaryError.signedOut
        case .notFound: throw RunSummaryError.notFound
        case .badRequest, .undocumented: throw RunSummaryError.server
        }
    }

    func generate(activityId: String, today: String) async throws -> RunSummaryResult {
        let output = try await call { try await client.generateRunSummary(path: .init(activityId: activityId), query: .init(today: today)) }
        switch output {
        case .ok(let ok): return Self.result(try ok.body.json)
        case .unauthorized: throw RunSummaryError.signedOut
        case .notFound: throw RunSummaryError.notFound
        case .tooManyRequests: throw RunSummaryError.rateLimited
        case .badRequest, .undocumented: throw RunSummaryError.server
        }
    }

    func aiEnabled() async throws -> Bool {
        try await profile().aiSummaries ?? true
    }

    /// Reads the profile first for its revision: only `aiSummaries` is sent, the other sections stay as they are.
    func setAIEnabled(_ on: Bool) async throws {
        let current = try await profile()
        let output = try await call { try await client.updateProfile(headers: .init(If_hyphen_Match: "\"\(current.revision)\""), body: .json(.init(aiSummaries: on))) }
        switch output {
        case .ok: return
        case .unauthorized: throw RunSummaryError.signedOut
        case .badRequest, .conflict, .undocumented: throw RunSummaryError.server
        }
    }

    static func result(_ summary: Components.Schemas.RunSummary) -> RunSummaryResult {
        RunSummaryResult(text: summary.text, nextStep: summary.nextStep, isAI: summary.source == .ai, canGenerate: summary.canGenerate, pain: summary.pain)
    }

    private func profile() async throws -> Components.Schemas.Profile {
        let output = try await call { try await client.getProfile() }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw RunSummaryError.signedOut
        case .undocumented: throw RunSummaryError.server
        }
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            throw underlying is URLError || (underlying as? SignInError) == .offline ? RunSummaryError.offline : RunSummaryError.server
        }
    }
}
