import Foundation
import Security

/// Result of a Keychain read. `unavailable` means the item may exist but can't be read
/// right now (before first unlock after a reboot), so callers must not mint a new value.
enum KeychainReadResult: Equatable {
    case found(String)
    case notFound
    case unavailable(OSStatus)
    /// Any other failure (e.g. missing entitlements in a macOS CLI).
    case failed(OSStatus)

    var value: String? {
        if case .found(let value) = self { return value }
        return nil
    }

    static func from(status: OSStatus, data: Data?) -> KeychainReadResult {
        switch status {
        case errSecSuccess:
            guard let data, let value = String(data: data, encoding: .utf8) else { return .failed(status) }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .unavailable(status)
        default:
            return .failed(status)
        }
    }
}

enum KeychainHelper {
    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.apprefer.sdk",
        ]
    }

    /// Writes or replaces the value.
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query = baseQuery(key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return add(key: key, value: value) == errSecSuccess
    }

    /// Adds the value only if no item exists. Returns `errSecDuplicateItem` when one does.
    static func add(key: String, value: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> KeychainReadResult {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return .from(status: status, data: result as? Data)
    }

    static func delete(key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
