import Foundation

final class AppReferStorage: @unchecked Sendable {
    private static let keyDeviceId = "apprefer_device_id"
    private static let keyFirstRunDate = "apprefer_first_run_date"
    private static let keyInstallEventSent = "apprefer_install_event_sent"
    private static let keyMatchRequestAttempted = "apprefer_match_request_attempted"
    private static let keyAttributionCache = "apprefer_attribution_cache"
    private static let keySdkEnabled = "apprefer_sdk_enabled"
    private static let keyLastConfigFetch = "apprefer_last_config_fetch"
    private static let keyUserId = "apprefer_user_id"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Device ID (Keychain — persists across reinstalls)

    func getDeviceId() -> String {
        if let existing = KeychainHelper.load(key: Self.keyDeviceId) {
            return existing
        }
        let newId = UUID().uuidString.lowercased()
        _ = KeychainHelper.save(key: Self.keyDeviceId, value: newId)
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
