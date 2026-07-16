import Foundation
import Security

/// Stores the API bearer token in the login keychain. UserDefaults is a
/// plaintext plist on disk — readable by any process running as the user and
/// included in unencrypted backups — so the token must not live there.
public enum KeychainStore {
    private static let service = "GIFGallery"
    private static let account = "bearerToken"

    /// Returns the stored token, migrating any token left behind in
    /// UserDefaults by older builds into the keychain (and scrubbing it).
    public static func loadToken() -> String? {
        if let token = read() {
            scrubLegacyDefaults()
            return token
        }
        if let legacy = UserDefaults.standard.string(forKey: "bearerToken"),
           !legacy.isEmpty {
            save(legacy)
            scrubLegacyDefaults()
            return legacy
        }
        return nil
    }

    public static func saveToken(_ token: String) {
        if token.isEmpty {
            SecItemDelete(baseQuery() as CFDictionary)
        } else {
            save(token)
        }
    }

    private static func scrubLegacyDefaults() {
        UserDefaults.standard.removeObject(forKey: "bearerToken")
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    private static func save(_ token: String) {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery()
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }
}
