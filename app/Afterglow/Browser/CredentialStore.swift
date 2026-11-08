import Foundation
import Security

/// Usernames and passwords for sites, in the Keychain in the Unity app's own item format
/// (`AfterglowKeychain.mm`: a generic password whose service is the site's host and whose
/// account is the username, or "(password only)" when there is none), so logins saved by either
/// app serve the other. Never logged.
struct Credential: Equatable, Sendable {
    var host: String
    var username: String
    var password: String
}

enum CredentialStore {
    static let passwordOnlyAccount = "(password only)"

    static func save(_ credential: Credential) -> Bool {
        let account = credential.username.isEmpty ? passwordOnlyAccount : credential.username
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credential.host,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(credential.password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = Data(credential.password.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func credentials(for host: String) -> [Credential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: host,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data, let password = String(data: data, encoding: .utf8) else { return nil }
            let account = item[kSecAttrAccount as String] as? String ?? ""
            return Credential(host: host, username: account == passwordOnlyAccount ? "" : account, password: password)
        }
    }

    static func delete(host: String, username: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: host,
            kSecAttrAccount as String: username.isEmpty ? passwordOnlyAccount : username,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
