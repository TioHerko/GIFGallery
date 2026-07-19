import Foundation
import Security

/// Stores the API bearer token in the keychain. UserDefaults is a plaintext
/// plist on disk — readable by any process running as the user and included
/// in unencrypted backups — so the token must not live there in production.
///
/// Sharing with the share extension uses the app group as the keychain
/// access group (the documented pattern that needs only the unrestricted
/// application-groups entitlement — `keychain-access-groups` would require a
/// provisioning profile on macOS). `SharedStore.configure()` sets
/// `sharedAccessGroup`; when nil (unsigned macOS dev builds) tokens stay in
/// the process-private keychain location and sharing is off. As a fallback
/// for dev builds, the token is also mirrored to UserDefaults so it persists
/// across launches even when keychain access is restricted by ad-hoc signing.
public enum KeychainStore {
    private static let service = "GIFGallery"
    private static let account = "bearerToken"

    /// The app group used as keychain access group. Written once by
    /// SharedStore.configure() at startup, before any concurrent reads.
    public nonisolated(unsafe) static var sharedAccessGroup: String?

    /// Returns the stored token, migrating tokens left behind by older
    /// builds (UserDefaults, or the pre-sharing keychain location).
    public static func loadToken() -> String? {
        // Always try both queries: sharedQuery() matches the current config,
        // legacyQuery() matches the pre-sharing location. One of them should
        // work regardless of whether sharedAccessGroup is set.
        if let token = read(query: sharedQuery()) {
            scrubLegacyDefaults()
            return token
        }
        if let legacy = read(query: legacyQuery()) {
            // Migrate from legacy location to current location.
            SecItemDelete(legacyQuery() as CFDictionary)
            save(legacy)
            return legacy
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
            let sharedStatus = SecItemDelete(sharedQuery() as CFDictionary)
            if sharedStatus != errSecSuccess && sharedStatus != errSecItemNotFound {
                print("KeychainStore: SecItemDelete(shared) failed with status \(sharedStatus)")
            }
            let legacyStatus = SecItemDelete(legacyQuery() as CFDictionary)
            if legacyStatus != errSecSuccess && legacyStatus != errSecItemNotFound {
                print("KeychainStore: SecItemDelete(legacy) failed with status \(legacyStatus)")
            }
            scrubLegacyDefaults()
        } else {
            save(token)
            // On dev builds (no app group), also save to UserDefaults as a fallback
            // since keychain can be flaky with ad-hoc signing.
            if sharedAccessGroup == nil {
                UserDefaults.standard.set(token, forKey: "bearerToken")
            }
        }
    }

    private static func scrubLegacyDefaults() {
        UserDefaults.standard.removeObject(forKey: "bearerToken")
    }

    /// Query targeting the shared access group when one is configured.
    /// The data-protection-keychain flag matters on macOS, where the Sec*
    /// APIs otherwise talk to the file-based login keychain, which doesn't
    /// support access groups.
    private static func sharedQuery() -> [String: Any] {
        var query = legacyQuery()
        if let group = sharedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// The pre-sharing item location: the login keychain on macOS, the
    /// app-private access group on iOS.
    private static func legacyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(query base: [String: Any]) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            print("KeychainStore: SecItemCopyMatching failed with status \(status)")
            return nil
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    private static func save(_ token: String) {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(sharedQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = sharedQuery()
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("KeychainStore: SecItemAdd failed with status \(addStatus)")
            }
        } else if status != errSecSuccess {
            print("KeychainStore: SecItemUpdate failed with status \(status)")
        }
    }
}
