import Foundation
import Security

/// API keys for remote models, one per format, as generic passwords in the login Keychain. Keys never go to
/// UserDefaults, `jot settings`, diagnostics or logs.
public enum ModelKeyStore {
    static let service = "space.jot.app.model-key"

    public static func key(for format: RemoteModelConfiguration.Format) -> String? {
        var query = baseQuery(format)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hasKey(for format: RemoteModelConfiguration.Format) -> Bool { key(for: format) != nil }

    /// Saves the key, replacing any earlier one. A blank key removes it.
    @discardableResult
    public static func save(_ key: String, for format: RemoteModelConfiguration.Format) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return remove(for: format) }
        let data = Data(key.utf8)
        let status = SecItemUpdate(baseQuery(format) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = baseQuery(format)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Jot model API key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func remove(for format: RemoteModelConfiguration.Format) -> Bool {
        let status = SecItemDelete(baseQuery(format) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(_ format: RemoteModelConfiguration.Format) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: format.rawValue]
    }
}
