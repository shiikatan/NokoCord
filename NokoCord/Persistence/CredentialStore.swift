import Foundation
import Security

struct CredentialStore {
    private let service = "com.nokocord.NokoCord.oauth"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecAttrAccount as String: "primary"] }
    func load() throws -> OAuthCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TransportError.keychain(status) }
        return try JSONDecoder().decode(OAuthCredentials.self, from: data)
    }
    func save(_ credentials: OAuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw TransportError.keychain(result) }
        } else if status != errSecSuccess { throw TransportError.keychain(status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TransportError.keychain(status) }
    }
}
