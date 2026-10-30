import APIClient
import Foundation

/// Why a plan could not be saved.
enum SaveError: Error, Equatable {
    /// The server refused the tokens (or there were none): sign in, then save again.
    case signedOut
    /// The plan id is already used for a different plan.
    case conflict
    case offline
    case server
}

protocol PlanSaving: Sendable {
    /// Creates the plan and returns its id. Repeating it for the same preview is safe: the server replays the create.
    func save(_ preview: SavedPreview) async throws -> String
}

/// Calls `POST /v1/plans` through a client that carries the user's token (`AuthMiddleware`).
struct APIPlanSaver: PlanSaving {
    let client: Client

    func save(_ preview: SavedPreview) async throws -> String {
        let body = try Self.body(for: preview)
        let output: Operations.createPlan.Output
        do {
            output = try await client.createPlan(body: .json(body))
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            // No network, here or in the middleware's token refresh, is an offline problem; anything else the server's.
            let offline = underlying is URLError || (underlying as? SignInError) == .offline
            throw offline ? SaveError.offline : SaveError.server
        }
        switch output {
        case .created, .ok: return preview.ids.plan
        case .unauthorized: throw SaveError.signedOut
        case .conflict: throw SaveError.conflict
        case .badRequest, .contentTooLarge, .undocumented: throw SaveError.server
        }
    }

    /// The draft's plan fields plus the stored ids. `PlanCreate` forbids unknown fields, so the draft's assumptions
    /// and warnings (which only the preview shows) are left out.
    static func body(for preview: SavedPreview) throws -> Components.Schemas.PlanCreate {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preview.draft)) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]],
              sessions.count == preview.ids.sessions.count
        else { throw SaveError.server }
        object["assumptions"] = nil
        object["warnings"] = nil
        object["id"] = preview.ids.plan
        object["sessions"] = zip(sessions, preview.ids.sessions).map { session, id in session.merging(["id": id]) { $1 } }
        return try JSONDecoder().decode(Components.Schemas.PlanCreate.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
