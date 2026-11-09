import APIClient
import Foundation

/// The user's heart-rate settings from the profile: the maximum they typed (never inferred, design §6.3) and any zones
/// of their own. Run details asks for the maximum once.
protocol MaxHeartRateServing: Sendable {
    func load() async throws -> Components.Schemas.HeartRateSettings
    /// Saves the maximum and sends the user's zones back with it: a `heartRate` update replaces the whole section.
    func save(maxBpm: Int) async throws
}

struct APIMaxHeartRateService: MaxHeartRateServing {
    let client: Client

    func load() async throws -> Components.Schemas.HeartRateSettings {
        try await profile().heartRate
    }

    func save(maxBpm: Int) async throws {
        let current = try await profile()
        let update = Components.Schemas.ProfileUpdate(heartRate: .init(maxBpm: maxBpm, zones: current.heartRate.zones))
        let output = try await call { try await client.updateProfile(headers: .init(If_hyphen_Match: "\"\(current.revision)\""), body: .json(update)) }
        switch output {
        case .ok: return
        case .badRequest, .conflict: throw InboxError.invalid
        case .unauthorized: throw InboxError.signedOut
        case .undocumented: throw InboxError.server
        }
    }

    private func profile() async throws -> Components.Schemas.Profile {
        let output = try await call { try await client.getProfile() }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw InboxError.signedOut
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
