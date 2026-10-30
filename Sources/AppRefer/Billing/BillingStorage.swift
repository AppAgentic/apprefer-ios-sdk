import Foundation
import CryptoKit
import Security

/// Small key-value store for values that must survive reinstalls (the anonymous id).
protocol BillingSecureStore: AnyObject {
    func read(_ key: String) -> KeychainReadResult
    /// Returns whether the value is now stored.
    @discardableResult
    func set(_ value: String?, forKey key: String) -> Bool
}

/// Keychain-backed store. If the Keychain write fails (e.g. a macOS CLI without
/// entitlements), the value is kept in UserDefaults so the id is at least stable per install.
final class KeychainBillingSecureStore: BillingSecureStore {
    private let defaults: UserDefaults
    private let fallbackPrefix = "apprefer_billing_kc_fallback_"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read(_ key: String) -> KeychainReadResult {
        let result = KeychainHelper.load(key: key)
        switch result {
        case .found, .unavailable:
            return result
        case .notFound:
            return defaults.string(forKey: fallbackPrefix + key).map { .found($0) } ?? result
        case .failed(let status):
            if let value = defaults.string(forKey: fallbackPrefix + key) { return .found(value) }
            // No Keychain at all (macOS CLI without entitlements): the UserDefaults copy is
            // the store, so its absence is a real absence. Other failures stay unknown.
            return status == errSecMissingEntitlement ? .notFound : result
        }
    }

    @discardableResult
    func set(_ value: String?, forKey key: String) -> Bool {
        guard let value else {
            KeychainHelper.delete(key: key)
            defaults.removeObject(forKey: fallbackPrefix + key)
            return true
        }
        if KeychainHelper.save(key: key, value: value) {
            defaults.removeObject(forKey: fallbackPrefix + key)
            return true
        }
        defaults.set(value, forKey: fallbackPrefix + key)
        return defaults.string(forKey: fallbackPrefix + key) == value
    }
}

final class InMemoryBillingSecureStore: BillingSecureStore {
    private var values: [String: String] = [:]
    /// Simulates the Keychain before first unlock.
    var isLocked = false
    /// Simulates any other Keychain read failure.
    var readFailure: OSStatus?
    /// Simulates a Keychain write failure.
    var failWrites = false

    func read(_ key: String) -> KeychainReadResult {
        if isLocked { return .unavailable(errSecInteractionNotAllowed) }
        if let readFailure { return .failed(readFailure) }
        return values[key].map { .found($0) } ?? .notFound
    }

    @discardableResult
    func set(_ value: String?, forKey key: String) -> Bool {
        if isLocked || failWrites { return false }
        values[key] = value
        return true
    }
}

/// Persistent billing state. Not thread-safe; owned by `BillingEngine` (an actor).
final class BillingStorage {
    static let anonymousPrefix = "$ARAnon:"

    private enum Key {
        static let anonymousId = "apprefer_billing_anonymous_id"
        static let appUserId = "apprefer_billing_app_user_id"
        static let accountTokens = "apprefer_billing_account_tokens"
        static let pendingAttributes = "apprefer_billing_pending_attributes"
        static let learnedEntitlements = "apprefer_billing_learned_entitlements"
        static let pendingIdentify = "apprefer_billing_pending_identify"
        static let pendingIdentifies = "apprefer_billing_pending_identifies"
        static let resetUser = "apprefer_billing_reset_user"
    }

    let directory: URL
    private let secure: BillingSecureStore
    private let defaults: UserDefaults

    init(secure: BillingSecureStore, defaults: UserDefaults, directory: URL, createDirectory: Bool = true) {
        self.secure = secure
        self.defaults = defaults
        self.directory = directory
        if createDirectory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    static func live(createDirectory: Bool = true) -> BillingStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return BillingStorage(
            secure: KeychainBillingSecureStore(),
            defaults: .standard,
            directory: base.appendingPathComponent("AppRefer/Billing", isDirectory: true),
            createDirectory: createDirectory
        )
    }

    static func isAnonymous(_ appUserId: String) -> Bool {
        appUserId.hasPrefix(anonymousPrefix)
    }

    private var importedIds = Set<String>()
    func isMigrationPurchase(_ id: String) -> Bool {
        importedIds.contains(id) || FileManager.default.fileExists(atPath: importURL(id).path)
    }
    func markMigrationPurchase(_ id: String) -> Bool {
        do {
            try Self.writeChecked(Data("readonly".utf8), to: importURL(id))
            importedIds.insert(id)
            return true
        }
        catch { return false }
    }
    private func importURL(_ id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("migration-purchase-\(key).flag")
    }

    func migrationSynced(_ user: String) -> Bool {
        (try? Data(contentsOf: migrationURL(user))) == Data("done".utf8)
    }

    @discardableResult
    func markMigrationSynced(_ user: String) -> Bool {
        do { try Self.writeChecked(Data("done".utf8), to: migrationURL(user)); return true }
        catch { return false }
    }

    private func migrationURL(_ user: String) -> URL {
        let key = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("migration-v2-\(key).flag")
    }

    // MARK: - Identity

    var hasAnonymousId: Bool { secure.read(Key.anonymousId).value != nil }

    /// False before first unlock after a reboot: the Keychain (and UserDefaults) can't
    /// be read, so the user's identity is unknown and nothing may be minted or sent.
    var isProtectedDataAvailable: Bool {
        if case .unavailable = secure.read(Key.anonymousId) { return false }
        return true
    }

    enum StoredAnonymousId: Equatable {
        case found(String)
        /// Confirmed: no anonymous id was ever saved.
        case absent
        /// The Keychain couldn't be read (locked or failing): the id may exist.
        case unknown
    }

    /// The saved anonymous id, without minting one.
    var storedAnonymousId: StoredAnonymousId {
        switch secure.read(Key.anonymousId) {
        case .found(let existing): return Self.isAnonymous(existing) ? .found(existing) : .absent
        case .notFound: return .absent
        case .unavailable, .failed: return .unknown
        }
    }

    /// `$ARAnon:<UUID>`, minted once and kept in the Keychain (survives reinstalls).
    /// Minted only when the Keychain confirms there is none, and returned only once it
    /// is saved; nil otherwise, so an unsaved or replacement id is never used.
    func anonymousId() -> String? {
        switch storedAnonymousId {
        case .found(let existing): return existing
        case .absent: return resetAnonymousId()
        case .unknown: return nil
        }
    }

    /// A new anonymous id, or nil when it couldn't be saved.
    @discardableResult
    func resetAnonymousId() -> String? {
        let id = Self.anonymousPrefix + UUID().uuidString
        return secure.set(id, forKey: Key.anonymousId) ? id : nil
    }

    /// The logged-in app user id, or nil while anonymous.
    var loggedInAppUserId: String? {
        get { defaults.string(forKey: Key.appUserId) }
        set { defaults.set(newValue, forKey: Key.appUserId) }
    }

    /// The current Billing user as stored, without minting an anonymous id: nil when
    /// Billing never had one (or it can't be read).
    var storedCurrentAppUserId: String? {
        if let loggedIn = loggedInAppUserId { return loggedIn }
        if case .found(let anonymousId) = storedAnonymousId { return anonymousId }
        return nil
    }

    // MARK: - Account reset marker (survives relaunch)

    enum StoredResetUser: Equatable {
        case none
        case user(String)
        /// The secure store couldn't be read (locked or failing): a marker may exist.
        case unknown
    }

    /// The reset marker, kept in the secure store (Keychain) with the anonymous id it guards,
    /// so a reinstall that keeps the Keychain identity keeps the marker too. A UserDefaults
    /// copy (written by pre-release 0.9.3 builds) is moved there on first read, and kept if
    /// the move fails.
    var storedResetUser: StoredResetUser {
        switch secure.read(Key.resetUser) {
        case .found(let marker): return .user(marker)
        case .unavailable, .failed: return .unknown
        case .notFound:
            guard let legacy = defaults.string(forKey: Key.resetUser) else { return .none }
            if secure.set(legacy, forKey: Key.resetUser) { defaults.removeObject(forKey: Key.resetUser) }
            return .user(legacy)
        }
    }

    /// The Billing user that was current when `AppRefer.reset()` last ran. While it is still
    /// the current user, that user belongs to the previous account: no install device id,
    /// device attributes or re-link, and identify sends `link: false`. Cleared by an explicit
    /// logIn/logOut and once the Billing user changes to a different id.
    var resetUser: String? {
        get { if case .user(let marker) = storedResetUser { return marker }; return nil }
        set {
            if secure.set(newValue, forKey: Key.resetUser) || newValue == nil { defaults.removeObject(forKey: Key.resetUser) }
            else { defaults.set(newValue, forKey: Key.resetUser) }
        }
    }

    /// Called by reset() when Billing isn't configured in this process: remembers the stored
    /// Billing user (anonymous or not). Nothing is stored when Billing never had a user.
    func recordAccountReset() {
        guard let current = storedCurrentAppUserId else { return }
        resetUser = current
    }

    /// True while the reset marker names the current Billing user `user`, or can't be ruled
    /// out (user or marker unreadable: fail closed). A marker for a different user is
    /// cleared: the Billing user has changed.
    func resetMarkerHolds(for user: String?) -> Bool {
        switch storedResetUser {
        case .none: return false
        case .unknown: return true
        case .user(let marker):
            guard let user else { return true }
            if marker == user { return true }
            resetUser = nil
            return false
        }
    }

    /// Nil only while protected data is unavailable.
    var currentAppUserId: String? {
        guard isProtectedDataAvailable else { return nil }
        return loggedInAppUserId ?? anonymousId()
    }

    // MARK: - Account tokens (Apple appAccountToken per app user)

    func legacyAccountToken(for user: String) -> UUID? {
        (defaults.dictionary(forKey: "apprefer_billing_legacy_tokens") as? [String: String])?[user].flatMap(UUID.init(uuidString:))
    }
    func setLegacyAccountToken(_ token: String?, for user: String) {
        var all = defaults.dictionary(forKey: "apprefer_billing_legacy_tokens") as? [String: String] ?? [:]
        all[user] = token.flatMap { UUID(uuidString: $0)?.uuidString }
        defaults.set(all, forKey: "apprefer_billing_legacy_tokens")
    }

    func accountToken(for appUserId: String) -> UUID? {
        guard let raw = (defaults.dictionary(forKey: Key.accountTokens) as? [String: String])?[appUserId] else { return nil }
        return UUID(uuidString: raw)
    }

    /// The app user a purchase's `appAccountToken` belongs to, if this device knows it.
    func appUserId(forAccountToken token: UUID) -> String? {
        let all = defaults.dictionary(forKey: Key.accountTokens) as? [String: String] ?? [:]
        return all.first { UUID(uuidString: $0.value) == token }?.key
            ?? (defaults.dictionary(forKey: "apprefer_billing_legacy_tokens") as? [String: String] ?? [:]).first { UUID(uuidString: $0.value) == token }?.key
    }

    func setAccountToken(_ token: String, for appUserId: String) {
        guard UUID(uuidString: token) != nil else { return }
        var all = defaults.dictionary(forKey: Key.accountTokens) as? [String: String] ?? [:]
        all[appUserId] = token
        defaults.set(all, forKey: Key.accountTokens)
    }

    // MARK: - Attributes waiting to be sent

    var pendingAttributes: [String: String] {
        defaults.dictionary(forKey: Key.pendingAttributes) as? [String: String] ?? [:]
    }

    func mergePendingAttributes(_ attributes: [String: String]) {
        var all = pendingAttributes
        all.merge(attributes) { _, new in new }
        defaults.set(all, forKey: Key.pendingAttributes)
    }

    /// Removes attributes that were sent, unless they changed while the request was in flight.
    func clearSentAttributes(_ sent: [String: String]) {
        var all = pendingAttributes
        for (key, value) in sent where all[key] == value { all.removeValue(forKey: key) }
        defaults.set(all, forKey: Key.pendingAttributes)
    }

    // MARK: - productId -> entitlement ids learned from server responses

    var learnedEntitlements: [String: [String]] {
        defaults.dictionary(forKey: Key.learnedEntitlements) as? [String: [String]] ?? [:]
    }

    func learnEntitlements(from info: AppReferCustomerInfo) {
        var map = learnedEntitlements
        var changed = false
        for (id, ent) in info.entitlements.all where !ent.productIdentifier.isEmpty {
            var ids = map[ent.productIdentifier] ?? []
            if !ids.contains(id) {
                ids.append(id)
                map[ent.productIdentifier] = ids.sorted()
                changed = true
            }
        }
        if changed { defaults.set(map, forKey: Key.learnedEntitlements) }
    }

    // MARK: - logIns that still need to reach the server

    struct PendingIdentify: Codable, Equatable {
        let anonymousId: String
        let appUserId: String
    }

    /// Anonymous → user merges not yet confirmed by the server, oldest first. Kept across
    /// logOut so a purchase made while anonymous still reaches the user it belongs to.
    var pendingIdentifies: [PendingIdentify] {
        get {
            if let data = defaults.data(forKey: Key.pendingIdentifies),
               let list = try? JSONDecoder().decode([PendingIdentify].self, from: data) {
                return list
            }
            // Written by earlier builds as a single dictionary.
            if let d = defaults.dictionary(forKey: Key.pendingIdentify) as? [String: String],
               let anon = d["anonymousId"], let user = d["appUserId"] {
                return [PendingIdentify(anonymousId: anon, appUserId: user)]
            }
            return []
        }
        set {
            defaults.removeObject(forKey: Key.pendingIdentify)
            if newValue.isEmpty {
                defaults.removeObject(forKey: Key.pendingIdentifies)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.pendingIdentifies)
            }
        }
    }

    func addPendingIdentify(anonymousId: String, appUserId: String) {
        let entry = PendingIdentify(anonymousId: anonymousId, appUserId: appUserId)
        var list = pendingIdentifies
        guard !list.contains(entry) else { return }
        list.append(entry)
        pendingIdentifies = list
    }

    func removePendingIdentify(_ entry: PendingIdentify) {
        pendingIdentifies = pendingIdentifies.filter { $0 != entry }
    }

    // MARK: - Cached CustomerInfo (last server answer)

    func offeringsBucketId() -> String? {
        let key = "apprefer_billing_offerings_bucket"
        switch secure.read(key) {
        case .found(let value): return value
        case .unavailable, .failed: return nil
        case .notFound: break
        }
        guard let id = defaults.string(forKey: key) ?? anonymousId(), secure.set(id, forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return id
    }
    func cachedOfferings(for user: String) -> CachedOfferings? {
        guard let data = defaults.data(forKey: "apprefer_billing_offerings:" + user) else { return nil }
        return try? JSONDecoder().decode(CachedOfferings.self, from: data)
    }
    func saveOfferings(_ value: CachedOfferings, for user: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: "apprefer_billing_offerings:" + user)
    }
    private var customerInfoURL: URL { directory.appendingPathComponent("customer_info.json") }

    func cachedCustomerInfo() -> AppReferCustomerInfo? {
        guard let data = try? Data(contentsOf: customerInfoURL) else { return nil }
        return try? JSONDecoder().decode(AppReferCustomerInfo.self, from: data)
    }

    func setCachedCustomerInfo(_ info: AppReferCustomerInfo) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        Self.write(data, to: customerInfoURL)
    }

    static func write(_ data: Data, to url: URL) {
        try? writeChecked(data, to: url)
    }

    static func writeChecked(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}
