import Foundation
import Security

/// The Bambuddy API key, kept in the keychain per server.
enum Keychain {
    private static let service = "dev.rolottr.BambuBar.bambuddy-api-key"

    /// The item for a server. The App Store build keeps its keys in the data protection keychain, under its App
    /// Store identity: the login keychain would ask for permission (and block launch until answered) whenever it
    /// met a key saved by the differently signed GitHub build. Its sandbox starts with settings of its own anyway.
    private static func item(_ server: String) -> [String: Any] {
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
        #if APP_STORE
            item[kSecUseDataProtectionKeychain as String] = true
        #endif
        return item
    }

    static func apiKey(for server: String) -> String? {
        var query = item(server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setAPIKey(_ key: String, for server: String) {
        let data = Data(key.utf8)
        if SecItemUpdate(item(server) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = item(server)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Bambu Bar Bambuddy API key"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func removeAPIKey(for server: String) {
        SecItemDelete(item(server) as CFDictionary)
    }
}
