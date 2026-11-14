import Foundation
import Security

/// The transcript database key, one per user, as a generic password in the login keychain, the way `ModelKeyStore`
/// keeps API keys. The keychain records which program created the item, so every build signed with Jot's team
/// certificate reads it without a prompt and any other program asking for it gets the keychain's own dialog.
/// Agents never need it: Jot.app unlocks the history and serves it over the socket. The key is never logged, never
/// sent and never in `jot settings`; Settings → Privacy shows it on request, for opening this history on another Mac.
public enum StoreKeyStore {
    static let service = "space.jot.app.history-key"
    static let account = "transcripts"

    public static let missingKeyMessage = "Saved history is encrypted, and its key is not in this Mac's keychain. If the history came from another Mac, enter that Mac's history key in Settings → Privacy, then reopen Jot. Your history has been preserved."

    /// The saved key, or nil when none was saved on this Mac.
    public static func load() throws -> StoreKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.error("read", status) }
        return try StoreKey(bytes: data)
    }

    /// Makes and saves a new key. One already saved, by this or another Jot moments earlier, is returned instead.
    public static func create() throws -> StoreKey {
        let key = StoreKey.random()
        var item = baseQuery()
        item[kSecValueData as String] = key.bytes
        item[kSecAttrLabel as String] = "Jot history key"
        item[kSecAttrDescription as String] = "Unlocks Jot's saved transcripts on this Mac"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        guard status == errSecSuccess else { throw Self.error("save", status) }
        return key
    }

    /// Saves the key of a history copied from another Mac, replacing whatever this Mac had.
    public static func replace(with key: StoreKey) throws {
        let status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: key.bytes] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.error("replace", status) }
        var item = baseQuery()
        item[kSecValueData as String] = key.bytes
        item[kSecAttrLabel as String] = "Jot history key"
        item[kSecAttrDescription as String] = "Unlocks Jot's saved transcripts on this Mac"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.error("save", added) }
    }

    /// The key that opens the history in `directory`: the saved one, or a new one when nothing encrypted is there yet.
    /// An encrypted history with no saved key is left as it is; the error says where the key is.
    public static func keyForOpening(directory: URL) throws -> StoreKey {
        if let key = try load() { return key }
        if try TranscriptStore.hasEncryptedDatabase(in: directory) { throw StoreError.invalid(missingKeyMessage) }
        return try create()
    }

    private static func baseQuery() -> [String: Any] {
        // The file-based login keychain: the data-protection keychain needs a provisioning profile Jot does not carry.
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }

    private static func error(_ action: String, _ status: OSStatus) -> StoreError {
        let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "error \(status)"
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            return .invalid("Jot could not \(action) the history key because the keychain request was denied. Reopen Jot and allow it in the keychain dialog. Your history has been preserved.")
        case errSecInteractionNotAllowed:
            return .invalid("Jot could not \(action) the history key because the login keychain is locked. Log in to this Mac, then reopen Jot. Your history has been preserved.")
        default:
            return .invalid("Jot could not \(action) the history key: \(reason). Your history has been preserved.")
        }
    }
}
