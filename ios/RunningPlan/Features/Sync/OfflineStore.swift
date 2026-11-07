import APIClient
import Foundation

/// A conflict the user has to settle: our queued edit against the server's newer copy.
struct SyncConflict: Codable, Equatable, Identifiable, Sendable {
    /// The queued edit's idempotency key.
    let key: String
    let server: Components.Schemas.SyncResult.serverPayload

    var id: String { key }
}

/// Everything the device keeps for sync, per API host and account: the queue, the cursor, conflicts waiting for the
/// user, the plan as last seen (so the app opens offline) and the proposals.
struct OfflineState: Codable, Equatable, Sendable {
    var cursor: String?
    var queue = EditQueue()
    var conflicts: [SyncConflict] = []
    var proposals: [Components.Schemas.Proposal] = []
    var plan: Components.Schemas.PlanDetail?
}

protocol OfflineStoring: Sendable {
    func load(scope: String) -> OfflineState?
    func save(_ state: OfflineState, scope: String)
    func clear(scope: String)
}

/// One JSON file per scope in Application Support, written atomically.
struct FileOfflineStore: OfflineStoring {
    let directory: URL

    static var live: FileOfflineStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return FileOfflineStore(directory: base.appendingPathComponent("offline", isDirectory: true))
    }

    private func file(_ scope: String) -> URL {
        // A scope is "<host and port>|<user id>"; keep the file name to safe characters.
        let safe = scope.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(safe + ".json")
    }

    func load(scope: String) -> OfflineState? {
        guard let data = try? Data(contentsOf: file(scope)) else { return nil }
        return try? APIConfiguration.decoder.decode(OfflineState.self, from: data)
    }

    func save(_ state: OfflineState, scope: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? APIConfiguration.encoder.encode(state) else { return }
        try? data.write(to: file(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear(scope: String) {
        try? FileManager.default.removeItem(at: file(scope))
    }
}

/// For tests.
final class MemoryOfflineStore: OfflineStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: OfflineState] = [:]

    func load(scope: String) -> OfflineState? { lock.withLock { states[scope] } }
    func save(_ state: OfflineState, scope: String) { lock.withLock { states[scope] = state } }
    func clear(scope: String) { lock.withLock { states[scope] = nil } }
}

extension APIConfiguration {
    /// Encodes API JSON outside the client (the stored copy), the way `decoder` reads it.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, e in
            var container = e.singleValueContainer()
            try container.encode(try dateTranscoder.encode(date))
        }
        return encoder
    }
}
