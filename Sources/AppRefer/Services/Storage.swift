import Foundation
import Security

/// Keychain access for the device id, abstracted so the mint race is testable.
protocol DeviceIdKeychain: Sendable {
    func load(key: String) -> KeychainReadResult
    func add(key: String, value: String) -> OSStatus
}

struct LiveDeviceIdKeychain: DeviceIdKeychain {
    func load(key: String) -> KeychainReadResult { KeychainHelper.load(key: key) }
    func add(key: String, value: String) -> OSStatus { KeychainHelper.add(key: key, value: value) }
}

final class AppReferStorage: @unchecked Sendable {
    private static let keyDeviceId = "apprefer_device_id"
    private static let keyFirstRunDate = "apprefer_first_run_date"
    private static let keyInstallEventSent = "apprefer_install_event_sent"
    private static let keyMatchRequestAttempted = "apprefer_match_request_attempted"
    private static let keyAttributionCache = "apprefer_attribution_cache"
    private static let keySdkEnabled = "apprefer_sdk_enabled"
    private static let keyLastConfigFetch = "apprefer_last_config_fetch"
    private static let keyUserId = "apprefer_user_id"

    /// Process-wide: attribution and billing each create their own storage and may
    /// both ask for the device id on first launch.
    private static let deviceIdLock = NSLock()

    private let defaults: UserDefaults
    private let keychain: DeviceIdKeychain

    init(defaults: UserDefaults = .standard, keychain: DeviceIdKeychain = LiveDeviceIdKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    // MARK: - Device ID (Keychain — persists across reinstalls)

    func getDeviceId() -> String {
        deviceId() ?? UUID().uuidString.lowercased()
    }

    /// The device id, minted once. Nil while the Keychain is locked (before first unlock
    /// after a reboot): minting then would replace the real id.
    func deviceId() -> String? {
        Self.deviceIdLock.lock()
        defer { Self.deviceIdLock.unlock() }

        switch keychain.load(key: Self.keyDeviceId) {
        case .found(let existing): return existing
        case .unavailable: return nil
        case .notFound, .failed: break
        }
        let newId = UUID().uuidString.lowercased()
        if keychain.add(key: Self.keyDeviceId, value: newId) == errSecDuplicateItem {
            // Another process (e.g. an app extension) added one first: use theirs.
            return keychain.load(key: Self.keyDeviceId).value ?? newId
        }
        return newId
    }

    // MARK: - First Run Date

    func getFirstRunDate() -> String {
        if let existing = defaults.string(forKey: Self.keyFirstRunDate) {
            return existing
        }
        let now = ISO8601DateFormatter().string(from: Date())
        defaults.set(now, forKey: Self.keyFirstRunDate)
        return now
    }

    // MARK: - Install Event Sent

    func isInstallEventSent() -> Bool {
        defaults.bool(forKey: Self.keyInstallEventSent)
    }

    func setInstallEventSent(_ sent: Bool) {
        defaults.set(sent, forKey: Self.keyInstallEventSent)
    }

    // MARK: - Match Request Attempted

    func isMatchRequestAttempted() -> Bool {
        defaults.bool(forKey: Self.keyMatchRequestAttempted)
    }

    func setMatchRequestAttempted(_ attempted: Bool) {
        defaults.set(attempted, forKey: Self.keyMatchRequestAttempted)
    }

    // MARK: - Attribution Cache

    func getAttributionCache() -> String? {
        defaults.string(forKey: Self.keyAttributionCache)
    }

    func setAttributionCache(_ json: String) {
        defaults.set(json, forKey: Self.keyAttributionCache)
    }

    // MARK: - SDK Enabled (kill switch)

    func isSdkEnabled() -> Bool {
        if defaults.object(forKey: Self.keySdkEnabled) == nil {
            return true // default enabled
        }
        return defaults.bool(forKey: Self.keySdkEnabled)
    }

    func setSdkEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.keySdkEnabled)
    }

    // MARK: - Last Config Fetch

    func setLastConfigFetch(_ timestamp: String) {
        defaults.set(timestamp, forKey: Self.keyLastConfigFetch)
    }

    // MARK: - User ID

    func getUserId() -> String? {
        defaults.string(forKey: Self.keyUserId)
    }

    func setUserId(_ userId: String) {
        defaults.set(userId, forKey: Self.keyUserId)
    }

    // MARK: - Cached Attribution Parsing

    func getCachedAttribution() -> Attribution? {
        guard let json = getAttributionCache(),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Attribution.self, from: data)
    }
}
