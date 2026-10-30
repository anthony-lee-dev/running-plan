import Foundation
import Security

/// The signed-in user's tokens. Never logged, never in UserDefaults.
struct StoredTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var userId: String
}

protocol TokenStoring: Sendable {
    func load() -> StoredTokens?
    func save(_ tokens: StoredTokens) throws
    func clear()
}

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// Keeps the tokens in the Keychain, one item per API base URL, so tokens for the deployed API never go to a
/// local server or the other way round. Readable after first unlock (for a background import), never synced.
struct KeychainTokenStore: TokenStoring {
    let service: String
    private let account = "session"

    init(service: String) {
        self.service = service
    }

    static func service(for baseURL: URL, bundleID: String) -> String {
        let host = baseURL.host ?? "api"
        return "\(bundleID).tokens.\(host)" + (baseURL.port.map { ":\($0)" } ?? "")
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> StoredTokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    func save(_ tokens: StoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
