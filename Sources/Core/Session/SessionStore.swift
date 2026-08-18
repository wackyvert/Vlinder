import Foundation
import Security

/// A signed-in server session. All saved accounts are JSON-encoded into a
/// single Keychain generic-password item (Tuner's pattern, multi-account).
struct Session: Codable, Equatable, Identifiable {
    var serverURL: URL
    /// Optional LAN address; used instead of serverURL when reachable.
    var localURL: URL?
    var serverName: String?
    var userId: String
    var userName: String?
    var accessToken: String
    var deviceId: String

    var id: String { userId + "@" + serverURL.absoluteString }
}

struct StoredAccounts: Codable {
    var accounts: [Session] = []
    var activeId: String?
}

enum SessionStore {
    private static let service = "dev.jake.vlinder.session"
    private static let accountsItem = "accounts"
    private static let legacyItem = "session"
    private static let defaultsFallbackKey = "vlinder.accounts.fallback"
    private static let legacyDefaultsKey = "vlinder.session.fallback"

    static func load() -> StoredAccounts {
        if let data = readKeychain(account: accountsItem)
            ?? UserDefaults.standard.data(forKey: defaultsFallbackKey),
           let stored = try? JSONDecoder().decode(StoredAccounts.self, from: data) {
            return stored
        }
        // Migrate the v0.1 single-session item.
        if let data = readKeychain(account: legacyItem)
            ?? UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let single = try? JSONDecoder().decode(Session.self, from: data) {
            let migrated = StoredAccounts(accounts: [single], activeId: single.id)
            save(migrated)
            deleteKeychain(account: legacyItem)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return migrated
        }
        return StoredAccounts()
    }

    static func save(_ stored: StoredAccounts) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        if writeKeychain(account: accountsItem, data: data) {
            UserDefaults.standard.removeObject(forKey: defaultsFallbackKey)
        } else {
            // Unsigned dev builds can't reach the data-protection keychain; fall back.
            UserDefaults.standard.set(data, forKey: defaultsFallbackKey)
        }
    }

    static func clear() {
        deleteKeychain(account: accountsItem)
        deleteKeychain(account: legacyItem)
        UserDefaults.standard.removeObject(forKey: defaultsFallbackKey)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    // MARK: - Keychain plumbing

    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func readKeychain(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private static func writeKeychain(account: String, data: Data) -> Bool {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecSuccess {
            SecItemDelete(query as CFDictionary)
            var add = baseQuery(account: account)
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func deleteKeychain(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
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

/// App-lock passcode, kept out of UserDefaults.
enum AppLockStore {
    private static let service = "dev.jake.vlinder.applock"

    static var hasCode: Bool { readCode() != nil }

    static func setCode(_ code: String) {
        let query: [String: Any] = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: Data(code.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecSuccess {
            SecItemDelete(query as CFDictionary)
            var add = baseQuery()
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func verify(_ code: String) -> Bool {
        readCode() == code
    }

    static func clearCode() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func readCode() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "code",
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
