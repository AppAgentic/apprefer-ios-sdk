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
    private static let keyReportedTrackingConsent = "apprefer_reported_tracking_consent"
    private static let keyConversionFine = "apprefer_conversion_fine"
    private static let keyConversionCoarse = "apprefer_conversion_coarse"
    private static let keyConversionCheckedAt = "apprefer_conversion_checked_at"

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

    /// The device id, minted once. Nil while the Keychain is locked (before first unlock
    /// after a reboot) or failing: minting then would replace the real id. A new id is
    /// only returned once the Keychain has saved it.
    func deviceId() -> String? {
        Self.deviceIdLock.lock()
        defer { Self.deviceIdLock.unlock() }

        switch keychain.load(key: Self.keyDeviceId) {
        case .found(let existing): return existing
        case .unavailable, .failed: return nil
        case .notFound: break
        }
        let newId = UUID().uuidString.lowercased()
        switch keychain.add(key: Self.keyDeviceId, value: newId) {
        case errSecSuccess:
            return newId
        case errSecDuplicateItem:
            // Another process (e.g. an app extension) added one first: use theirs.
            return keychain.load(key: Self.keyDeviceId).value
        default:
            return nil
        }
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

    // MARK: - Tracking consent last accepted by the server

    func reportedTrackingConsent() -> String? {
        defaults.string(forKey: Self.keyReportedTrackingConsent)
    }

    func setReportedTrackingConsent(_ value: String) {
        defaults.set(value, forKey: Self.keyReportedTrackingConsent)
    }

    // MARK: - SKAdNetwork / AdAttributionKit value last set on the device

    func conversionValue() -> (fine: Int, coarse: String)? {
        guard defaults.object(forKey: Self.keyConversionFine) != nil else { return nil }
        return (defaults.integer(forKey: Self.keyConversionFine), defaults.string(forKey: Self.keyConversionCoarse) ?? "low")
    }

    func setConversionValue(fine: Int, coarse: String) {
        defaults.set(fine, forKey: Self.keyConversionFine)
        defaults.set(coarse, forKey: Self.keyConversionCoarse)
    }

    func conversionCheckedAt() -> Date? {
        defaults.object(forKey: Self.keyConversionCheckedAt) as? Date
    }

    func setConversionCheckedAt(_ date: Date) {
        defaults.set(date, forKey: Self.keyConversionCheckedAt)
    }

    /// When the first run was recorded, if it was.
    func firstRunDate() -> Date? {
        defaults.string(forKey: Self.keyFirstRunDate).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    // MARK: - Cached Attribution Parsing

    func getCachedAttribution() -> Attribution? {
        guard let json = getAttributionCache(),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Attribution.self, from: data)
    }
}
