import APIClient
import Foundation

enum SessionWriteError: Error, Equatable {
    /// The server refused the tokens even after a refresh.
    case signedOut
    /// The session changed elsewhere since it was read (`If-Match` did not match).
    case conflict
    case notFound
    case offline
    case server
}

/// Session edits, straight to the API while online (the offline queue is slice 5).
protocol SessionWriting: Sendable {
    func update(id: String, revision: Int, _ body: Components.Schemas.SessionUpdate) async throws -> Components.Schemas.SessionWriteResult
    func create(planId: String, _ body: Components.Schemas.SessionCreate) async throws -> Components.Schemas.SessionWriteResult
    func delete(id: String, revision: Int) async throws -> Components.Schemas.SessionWriteResult
    /// A before-session check-in; `id` is client-made so a retry is not stored twice.
    func checkIn(sessionId: String, feeling: BeforeFeeling, id: String) async throws
}

/// Calls the session endpoints through a client that carries the user's token (`AuthMiddleware`).
struct APISessionWriter: SessionWriting {
    let client: Client

    /// The base revision as the quoted entity tag the API expects (`If-Match: "3"`).
    private static func etag(_ revision: Int) -> String { "\"\(revision)\"" }

    func update(id: String, revision: Int, _ body: Components.Schemas.SessionUpdate) async throws -> Components.Schemas.SessionWriteResult {
        let output = try await call { try await client.updateSession(path: .init(sessionId: id), headers: .init(If_hyphen_Match: Self.etag(revision)), body: .json(body)) }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw SessionWriteError.signedOut
        case .conflict: throw SessionWriteError.conflict
        case .notFound: throw SessionWriteError.notFound
        case .badRequest, .undocumented: throw SessionWriteError.server
        }
    }

    func create(planId: String, _ body: Components.Schemas.SessionCreate) async throws -> Components.Schemas.SessionWriteResult {
        let output = try await call { try await client.createSession(path: .init(planId: planId), body: .json(body)) }
        switch output {
        case .created(let created): return try created.body.json
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw SessionWriteError.signedOut
        case .conflict: throw SessionWriteError.conflict
        case .notFound: throw SessionWriteError.notFound
        case .badRequest, .undocumented: throw SessionWriteError.server
        }
    }

    func delete(id: String, revision: Int) async throws -> Components.Schemas.SessionWriteResult {
        let output = try await call { try await client.deleteSession(path: .init(sessionId: id), headers: .init(If_hyphen_Match: Self.etag(revision))) }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw SessionWriteError.signedOut
        case .conflict: throw SessionWriteError.conflict
        case .notFound: throw SessionWriteError.notFound
        case .undocumented: throw SessionWriteError.server
        }
    }

    func checkIn(sessionId: String, feeling: BeforeFeeling, id: String) async throws {
        let body = Components.Schemas.CheckInCreate(value1: .init(when: .before, feel: feeling.feel), value2: .init(id: id))
        let output = try await call { try await client.createCheckIn(path: .init(sessionId: sessionId), body: .json(body)) }
        switch output {
        case .created, .ok: return
        case .unauthorized: throw SessionWriteError.signedOut
        case .notFound: throw SessionWriteError.notFound
        case .badRequest, .undocumented: throw SessionWriteError.server
        }
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            // No network, here or in the middleware's token refresh, is an offline problem; anything else the server's.
            throw underlying is URLError || (underlying as? SignInError) == .offline ? SessionWriteError.offline : SessionWriteError.server
        }
    }
}
