import Foundation
import Security

/// GitHub credentials for private-repo update checks. Prefers a Portside-owned
/// token in the keychain; falls back to a logged-in GitHub CLI (`gh`) token so
/// a personal install works with no extra setup.
///
/// Reminder: the repo is private today (`docs/github-visibility`). If it ever
/// goes public, follow docs/BUILD.md "When the GitHub repo becomes public"
/// (auth becomes optional; publish-release will fail until that file says public).
enum GitHubAuth {
    private static let portsideService = "com.james.portside.github-token"
    private static let portsideAccount = "token"
    private static let ghService = "gh:github.com"

    /// Bearer token for api.github.com, or nil when none is available.
    static func token() -> String? {
        if let own = readKeychain(service: portsideService, account: portsideAccount) {
            let trimmed = own.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ghCLIToken()
    }

    /// Presence checks read attributes only, never the secret. Reading a
    /// secret can wait on a keychain access prompt (a rebuilt or re-signed
    /// binary is not on the `gh` item's access list), and Settings asks on
    /// the main thread: that froze Portside for a minute on 2026-11-01.
    static var hasPortsideToken: Bool {
        !keychainAccounts(service: portsideService).isEmpty
    }

    /// True when a Portside token or a `gh` keychain token is stored.
    static var hasAnyToken: Bool {
        hasPortsideToken || !keychainAccounts(service: ghService).isEmpty
    }

    static func savePortsideToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearPortsideToken()
            return
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: portsideService,
            kSecAttrAccount as String: portsideAccount,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AuthError.keychain(addStatus) }
            return
        }
        throw AuthError.keychain(status)
    }

    static func clearPortsideToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: portsideService,
            kSecAttrAccount as String: portsideAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    /// `gh` stores tokens as `go-keyring-base64:<base64>` (go-keyring). Decode that;
    /// plain values (older hosts) are returned as-is.
    private static func ghCLIToken() -> String? {
        for account in keychainAccounts(service: ghService) {
            if let raw = readKeychain(service: ghService, account: account),
               let token = decodeKeyringValue(raw) {
                return token
            }
        }
        return nil
    }

    private static func decodeKeyringValue(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if value.hasPrefix(prefix) {
            let b64 = String(value.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: b64),
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty else { return nil }
            return token
        }
        return value.isEmpty ? nil : value
    }

    private static func readKeychain(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Account names for a service. The macOS file keychain rejects
    /// `kSecReturnData` with `kSecMatchLimitAll` (errSecParam), so list
    /// attributes here and read each password with a single match.
    /// Attributes need no access approval, so this never prompts.
    private static func keychainAccounts(service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let rows = item as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    enum AuthError: LocalizedError {
        case keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .keychain(let status): "keychain error \(status)"
            }
        }
    }
}
