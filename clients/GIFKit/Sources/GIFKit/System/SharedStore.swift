import Foundation
#if os(macOS)
import Security
#endif

/// Configuration shared between the app and its share extension through an
/// App Group.
///
/// iOS uses a fixed "group." identifier baked into both targets' entitlements.
/// macOS app groups must be prefixed with the Team ID, which is deliberately
/// kept out of the repo — so it is recovered at runtime from the running
/// code's own signature. Unsigned dev builds get nil and fall back to
/// process-private storage (the share extension requires a signed build
/// anyway, so nothing is lost).
public enum SharedStore {
    public static let serverURLKey = "serverURL"

    /// The app-group suite name, or nil when sharing isn't available.
    /// Written once by configure() at startup, before any concurrent reads.
    public private(set) nonisolated(unsafe) static var suiteName: String?

    public static var defaults: UserDefaults {
        guard let suiteName, let shared = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return shared
    }

    /// Call once at startup — in the app and in the share extension — before
    /// reading configuration. Safe to call repeatedly.
    public static func configure() {
        #if os(iOS)
        suiteName = "group.me.herko.GIFGallery"
        KeychainStore.sharedAccessGroup = suiteName
        #elseif os(macOS)
        if let team = teamIdentifier() {
            let group = "\(team).me.herko.gif.shared"
            suiteName = group
            KeychainStore.sharedAccessGroup = group
        }
        #endif
        migrateServerURL()
    }

    public static var serverURL: String? {
        get { defaults.string(forKey: serverURLKey) }
        set { defaults.set(newValue, forKey: serverURLKey) }
    }

    /// Builds an API client from the shared configuration, or nil when the
    /// server URL or token is missing/invalid.
    public static func makeClient() -> APIClient? {
        guard let urlString = serverURL,
              !urlString.isEmpty,
              let url = APIClient.validateBaseURL(urlString),
              let token = KeychainStore.loadToken()
        else { return nil }
        return APIClient(baseURL: url, token: token)
    }

    /// Copies a server URL saved by pre-app-group builds in the standard
    /// defaults into the shared suite.
    private static func migrateServerURL() {
        guard suiteName != nil,
              defaults.string(forKey: serverURLKey) == nil,
              let legacy = UserDefaults.standard.string(forKey: serverURLKey),
              !legacy.isEmpty
        else { return }
        defaults.set(legacy, forKey: serverURLKey)
    }

    #if os(macOS)
    /// The Team ID from the app bundle's Info.plist (embedded at build time),
    /// or nil if not set. This avoids relying on the code signature, which
    /// differs between ad-hoc and Developer ID signing.
    private static func teamIdentifier() -> String? {
        // First try the embedded TeamID key (set by build.sh / build-release.sh)
        if let team = Bundle.main.object(forInfoDictionaryKey: "TeamID") as? String,
           !team.isEmpty {
            return team
        }
        // Fallback: extract from code signature (for backwards compat with
        // already-deployed apps that don't have the embedded key).
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        ) == errSecSuccess,
            let dict = info as? [String: Any],
            let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        else { return nil }
        return team
    }
    #endif
}
