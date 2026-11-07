import APIClient
import Foundation

enum SyncError: Error, Equatable {
    /// The server refused the tokens even after a refresh. The queue stays.
    case signedOut
    case offline
    /// The whole request was refused (400): one operation is malformed.
    case badRequest
    /// The request was too big (413).
    case tooLarge
    case server
}

/// `POST /v1/sync`: pushes queued operations, then pulls changes since the cursor.
protocol SyncServing: Sendable {
    func sync(cursor: String?, operations: [SyncOp]) async throws -> Components.Schemas.SyncResponse
}

struct APISyncService: SyncServing {
    let client: Client

    func sync(cursor: String?, operations: [SyncOp]) async throws -> Components.Schemas.SyncResponse {
        let output: Operations.sync.Output
        do {
            output = try await client.sync(body: .json(.init(cursor: cursor, operations: operations)))
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            throw underlying is URLError || (underlying as? SignInError) == .offline ? SyncError.offline : SyncError.server
        }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw SyncError.signedOut
        case .badRequest: throw SyncError.badRequest
        case .contentTooLarge: throw SyncError.tooLarge
        case .undocumented: throw SyncError.server
        }
    }
}
