import APIClient
import Foundation

enum InboxError: Error, Equatable {
    case signedOut
    /// The token lacks `activities:write` (a web token), or the server refused the request.
    case forbidden
    case notFound
    case invalid
    case offline
    case server
}

/// The activity endpoints the inbox uses.
protocol InboxServing: Sendable {
    /// Activities waiting for review, newest first.
    func inbox() async throws -> [Components.Schemas.Activity]
    /// Every imported run, matched or not (each with its `match`), newest first.
    func allRuns() async throws -> [Components.Schemas.Activity]
    /// One upload of at most 200 records. Returns the suggested session per activity id.
    func upload(_ inputs: [Components.Schemas.ActivityInput]) async throws -> [String: String]
    func confirm(sessionId: String, activityId: String) async throws -> Components.Schemas.MatchWriteResult
    func unmatch(sessionId: String) async throws -> Components.Schemas.SessionWriteResult
    func setDisposition(activityId: String, _ disposition: Components.Schemas.ActivityUpdate.dispositionPayload) async throws
}

struct APIInboxService: InboxServing {
    let client: Client

    func inbox() async throws -> [Components.Schemas.Activity] {
        let output = try await call { try await client.listActivities(query: .init(inbox: true, limit: 200)) }
        switch output {
        case .ok(let ok): return try ok.body.json.activities
        case .unauthorized: throw InboxError.signedOut
        case .badRequest: throw InboxError.invalid
        case .undocumented: throw InboxError.server
        }
    }

    func allRuns() async throws -> [Components.Schemas.Activity] {
        var runs: [Components.Schemas.Activity] = []
        var cursor: String?
        // A cap on pages so a misbehaving cursor cannot loop forever (2000 runs).
        for _ in 0..<10 {
            let output = try await call { try await client.listActivities(query: .init(cursor: cursor, limit: 200)) }
            switch output {
            case .ok(let ok):
                let page = try ok.body.json
                runs += page.activities
                guard let next = page.nextCursor else { return runs }
                cursor = next
            case .unauthorized: throw InboxError.signedOut
            case .badRequest: throw InboxError.invalid
            case .undocumented: throw InboxError.server
            }
        }
        return runs
    }

    func upload(_ inputs: [Components.Schemas.ActivityInput]) async throws -> [String: String] {
        let output = try await call { try await client.importActivities(body: .json(.init(activities: inputs))) }
        switch output {
        case .ok(let ok):
            let results = try ok.body.json.results
            return Dictionary(results.compactMap { r in r.suggestedSessionId.map { (r.activityId, $0) } }, uniquingKeysWith: { first, _ in first })
        case .unauthorized: throw InboxError.signedOut
        case .forbidden: throw InboxError.forbidden
        case .badRequest, .contentTooLarge: throw InboxError.invalid
        case .undocumented: throw InboxError.server
        }
    }

    func confirm(sessionId: String, activityId: String) async throws -> Components.Schemas.MatchWriteResult {
        let output = try await call { try await client.putMatch(path: .init(sessionId: sessionId), body: .json(.init(activityId: activityId, status: .confirmed))) }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw InboxError.signedOut
        case .notFound: throw InboxError.notFound
        case .badRequest: throw InboxError.invalid
        case .undocumented: throw InboxError.server
        }
    }

    func unmatch(sessionId: String) async throws -> Components.Schemas.SessionWriteResult {
        let output = try await call { try await client.deleteMatch(path: .init(sessionId: sessionId)) }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw InboxError.signedOut
        case .notFound: throw InboxError.notFound
        case .undocumented: throw InboxError.server
        }
    }

    func setDisposition(activityId: String, _ disposition: Components.Schemas.ActivityUpdate.dispositionPayload) async throws {
        let output = try await call { try await client.updateActivity(path: .init(activityId: activityId), body: .json(.init(disposition: disposition))) }
        switch output {
        case .ok: return
        case .unauthorized: throw InboxError.signedOut
        case .notFound: throw InboxError.notFound
        case .badRequest: throw InboxError.invalid
        case .undocumented: throw InboxError.server
        }
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            throw underlying is URLError || (underlying as? SignInError) == .offline ? InboxError.offline : InboxError.server
        }
    }
}
