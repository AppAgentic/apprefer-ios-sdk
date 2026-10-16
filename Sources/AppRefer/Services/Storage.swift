import Foundation
import Security

/// Keychain access for the device id (and the Support identity-cleared flag), abstracted
/// so the mint race is testable.
protocol DeviceIdKeychain: Sendable {
    func load(key: String) -> KeychainReadResult
    func add(key: String, value: String) -> OSStatus
    /// Writes or replaces the value; false when it couldn't be saved.
    func save(key: String, value: String) -> Bool
    func delete(key: String)
}

struct LiveDeviceIdKeychain: DeviceIdKeychain {
    func load(key: String) -> KeychainReadResult { KeychainHelper.load(key: key) }
    func add(key: String, value: String) -> OSStatus { KeychainHelper.add(key: key, value: value) }
    func save(key: String, value: String) -> Bool { KeychainHelper.save(key: key, value: value) }
    func delete(key: String) { KeychainHelper.delete(key: key) }
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
    private let eventFileURL: URL?

    init(defaults: UserDefaults = .standard, keychain: DeviceIdKeychain = LiveDeviceIdKeychain(), eventFileURL: URL? = nil) {
        self.defaults = defaults
        self.keychain = keychain
        // Production uses the same checked atomic-file pattern as the purchase queue.
        // Custom defaults retain their isolated test store unless a file is injected.
        self.eventFileURL = eventFileURL ?? (defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("AppRefer/product-events.json") : nil)
    }

    private let collectionLock = NSLock()
    private var collectionPaused = false
    func isCollectionEnabled() -> Bool {
        collectionLock.lock(); defer { collectionLock.unlock() }
        return !collectionPaused && (defaults.object(forKey: "apprefer_collection_enabled") as? Bool != false)
    }
    func setCollectionEnabled(_ enabled: Bool) {
        collectionLock.lock(); defer { collectionLock.unlock() }
        // Turning off pauses at once; turning back on takes effect only on configure. An
        // unchanged "on" never pauses anything.
        if !enabled || defaults.object(forKey: "apprefer_collection_enabled") as? Bool == false { collectionPaused = true }
        defaults.set(enabled, forKey: "apprefer_collection_enabled")
    }
    /// The app saved "off". Only this (or the server kill switch) clears queued events; a pause
    /// waiting for configure after re-enabling does not.
    func collectionSavedOff() -> Bool {
        collectionLock.lock(); defer { collectionLock.unlock() }
        return defaults.object(forKey: "apprefer_collection_enabled") as? Bool == false
    }
    func resumeCollection() {
        collectionLock.lock(); defer { collectionLock.unlock() }
        collectionPaused = false
    }

    func clearUser() {
        defaults.removeObject(forKey: Self.keyUserId)
        supportIdentityCleared = false
    }
    /// Set by `AppRefer.support.clearIdentity()`: Support sends no app user id until the
    /// user id changes or reset() runs. Kept in the Keychain with the Support session token,
    /// so a reinstall whose session survives still knows it was cleared. 0.9.2 kept it in
    /// UserDefaults: that copy is moved on first read (and kept if the move fails).
    static let keySupportIdentityCleared = "apprefer_support_identity_cleared"
    var supportIdentityCleared: Bool {
        get {
            if case .found = keychain.load(key: Self.keySupportIdentityCleared) { return true }
            guard defaults.bool(forKey: Self.keySupportIdentityCleared) else { return false }
            if keychain.save(key: Self.keySupportIdentityCleared, value: "1") {
                defaults.removeObject(forKey: Self.keySupportIdentityCleared)
            }
            return true
        }
        set {
            if newValue {
                if keychain.save(key: Self.keySupportIdentityCleared, value: "1") { defaults.removeObject(forKey: Self.keySupportIdentityCleared) }
                else { defaults.set(true, forKey: Self.keySupportIdentityCleared) }
            } else {
                keychain.delete(key: Self.keySupportIdentityCleared)
                defaults.removeObject(forKey: Self.keySupportIdentityCleared)
            }
        }
    }
    var organicConfirmed: Bool {
        get { defaults.bool(forKey: "apprefer_organic_confirmed") }
        set { defaults.set(newValue, forKey: "apprefer_organic_confirmed") }
    }
    var pendingEvents: Data? {
        get { try? readPendingEvents() }
        set { try? writePendingEvents(newValue) }
    }

    func quarantinePendingEvents() throws {
        if let url = eventFileURL {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt-" + UUID().uuidString))
        } else {
            if let data = defaults.data(forKey: "apprefer_pending_events") {
                defaults.set(data, forKey: "apprefer_pending_events_corrupt")
            }
            defaults.removeObject(forKey: "apprefer_pending_events")
        }
    }

    func readPendingEvents() throws -> Data? {
        guard let url = eventFileURL else { return defaults.data(forKey: "apprefer_pending_events") }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writePendingEvents(_ data: Data?) throws {
        guard let url = eventFileURL else {
            defaults.set(data, forKey: "apprefer_pending_events")
            if data == nil { defaults.removeObject(forKey: "apprefer_pending_events_corrupt") }
            return
        }
        guard let data else {
            let siblings = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            for file in siblings where file.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt-") { try FileManager.default.removeItem(at: file) }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BillingStorage.writeChecked(data, to: url)
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
        if !enabled { pendingEvents = nil }
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
        // A different account ends a Support identity clear; the same id keeps it.
        if defaults.string(forKey: Self.keyUserId) != userId { supportIdentityCleared = false }
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
