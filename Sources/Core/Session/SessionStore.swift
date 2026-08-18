import Foundation
import Security

/// A signed-in server session. The whole struct is JSON-encoded into a single
/// Keychain generic-password item (Tuner's pattern).
struct Session: Codable, Equatable {
    var serverURL: URL
    var serverName: String?
    var userId: String
    var userName: String?
    var accessToken: String
    var deviceId: String
}

enum SessionStore {
    private static let service = "dev.jake.vlinder.session"
    private static let account = "session"
    private static let defaultsFallbackKey = "vlinder.session.fallback"

    static func load() -> Session? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            return session
        }
        // Unsigned dev builds can't reach the data-protection keychain; fall back.
        if let data = UserDefaults.standard.data(forKey: defaultsFallbackKey),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            return session
        }
        return nil
    }

    static func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecSuccess {
            SecItemDelete(query as CFDictionary)
            var add = baseQuery()
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            UserDefaults.standard.set(data, forKey: defaultsFallbackKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsFallbackKey)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: defaultsFallbackKey)
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        // Use the modern data-protection keychain instead of legacy file-based keychain.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

enum DeviceID {
    private static let key = "vlinder.deviceId"

    static func persistent() -> String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
