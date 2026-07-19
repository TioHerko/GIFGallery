import Foundation
import Security

/// Stores the API bearer token in the keychain. UserDefaults is a plaintext
/// plist on disk — readable by any process running as the user and included
/// in unencrypted backups — so the token must not live there in production.
///
/// iOS: the token lives in the data protection keychain under the app-group
/// access group (set via `sharedAccessGroup`) so the share extension can
/// read it; the provisioning profile authorizes the group.
///
/// macOS: the token lives in the login (file-based) keychain with NO access
/// group. The data protection keychain is unusable in these builds: without
/// a provisioning profile, secd grants the process no keychain access groups
/// at all — the application-groups entitlement is NOT honored for keychain
/// purposes (verified on macOS 26 with a Developer ID signature: every
/// SecItem call with kSecUseDataProtectionKeychain fails with
/// errSecMissingEntitlement/-34018, "Client has neither
/// com.apple.application-identifier nor com.apple.security.application-groups
/// nor keychain-access-groups entitlements"; sandboxed or not, timestamped
/// or not). The share extension reads the same login-keychain item; the
/// first read shows the system keychain prompt where the user can pick
/// "Always Allow".
///
/// Unsigned/ad-hoc macOS dev builds additionally mirror the token to
/// UserDefaults (`mirrorsToDefaults`) because login-keychain item ACLs are
/// keyed to the binary's signature, which churns on every rebuild.
public enum KeychainStore {
    private static let service = "GIFGallery"
    private static let account = "bearerToken"

    /// iOS only: the app group used as keychain access group. Written once by
    /// SharedStore.configure() at startup, before any concurrent reads.
    /// Never set on macOS — see the type comment.
    public nonisolated(unsafe) static var sharedAccessGroup: String?

    /// Mirror the token to UserDefaults (unsigned macOS dev builds only).
    /// Written once by SharedStore.configure() at startup.
    public nonisolated(unsafe) static var mirrorsToDefaults = false

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

    /// Returns false when the token could not be written to the keychain
    /// (so callers can surface the failure instead of losing it silently).
    @discardableResult
    public static func saveToken(_ token: String) -> Bool {
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
            return true
        } else {
            let saved = save(token)
            // On unsigned dev builds, also save to UserDefaults as a fallback
            // since keychain can be flaky with ad-hoc signing.
            if mirrorsToDefaults {
                UserDefaults.standard.set(token, forKey: "bearerToken")
                return true
            }
            return saved
        }
    }

    private static func scrubLegacyDefaults() {
        UserDefaults.standard.removeObject(forKey: "bearerToken")
    }

    /// Query targeting the shared access group when one is configured (iOS).
    /// With no group set this is identical to legacyQuery(): on macOS that
    /// means the file-based login keychain — deliberately, since the
    /// data protection keychain rejects these builds (see type comment).
    private static func sharedQuery() -> [String: Any] {
        var query = legacyQuery()
        if let group = sharedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// The default item location: the login keychain on macOS, the
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

    @discardableResult
    private static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(sharedQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = sharedQuery()
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("KeychainStore: SecItemAdd failed with status \(addStatus)")
                return false
            }
        } else if status != errSecSuccess {
            print("KeychainStore: SecItemUpdate failed with status \(status)")
            return false
        }
        return true
    }
}
