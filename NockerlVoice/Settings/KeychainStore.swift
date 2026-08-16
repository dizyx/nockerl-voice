import Foundation
import Security

/// Stores the cloud (OpenRouter) API key in the macOS Keychain (on-device).
/// Generic-password items under the app's service id.
enum KeychainStore {
    /// Per-install Keychain service, derived from the bundle id. Under the
    /// production bundle id this equals the pre-change literal `com.dizyx.nockerlvoice`
    /// (byte-identical); a fork under another id reads a DIFFERENT service, so a dev
    /// build can never read the production OpenRouter/custom key.
    private static let service = AppPaths.keychainService
    private static let cloudAccount = "openrouter-api-key"
    private static let customAccount = "custom-api-key"

    static func cloudKey() -> String? { value(account: cloudAccount) }
    static func customKey() -> String? { value(account: customAccount) }

    static func setCloudKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { delete(account: cloudAccount) } else { set(account: cloudAccount, value: trimmed) }
    }

    static func setCustomKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { delete(account: customAccount) } else { set(account: customAccount, value: trimmed) }
    }

    static func deleteCloudKey() { delete(account: cloudAccount) }
    static func deleteCustomKey() { delete(account: customAccount) }

    // MARK: - Generic-password helpers

    private static func set(account: String, value: String) {
        delete(account: account)
        guard let data = value.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func value(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
