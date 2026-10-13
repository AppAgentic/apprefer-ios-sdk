import Foundation

/// Small key-value store for values that must survive reinstalls (the anonymous id).
protocol BillingSecureStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// Keychain-backed store. If the Keychain write fails (e.g. a macOS CLI without
/// entitlements), the value is kept in UserDefaults so the id is at least stable per install.
final class KeychainBillingSecureStore: BillingSecureStore {
    private let defaults: UserDefaults
    private let fallbackPrefix = "apprefer_billing_kc_fallback_"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        KeychainHelper.load(key: key) ?? defaults.string(forKey: fallbackPrefix + key)
    }

    func set(_ value: String?, forKey key: String) {
        guard let value else {
            KeychainHelper.delete(key: key)
            defaults.removeObject(forKey: fallbackPrefix + key)
            return
        }
        if KeychainHelper.save(key: key, value: value) {
            defaults.removeObject(forKey: fallbackPrefix + key)
        } else {
            defaults.set(value, forKey: fallbackPrefix + key)
        }
    }
}

final class InMemoryBillingSecureStore: BillingSecureStore {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) { values[key] = value }
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
    }

    let directory: URL
    private let secure: BillingSecureStore
    private let defaults: UserDefaults

    init(secure: BillingSecureStore, defaults: UserDefaults, directory: URL) {
        self.secure = secure
        self.defaults = defaults
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func live() -> BillingStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return BillingStorage(
            secure: KeychainBillingSecureStore(),
            defaults: .standard,
            directory: base.appendingPathComponent("AppRefer/Billing", isDirectory: true)
        )
    }

    static func isAnonymous(_ appUserId: String) -> Bool {
        appUserId.hasPrefix(anonymousPrefix)
    }

    // MARK: - Identity

    var hasAnonymousId: Bool { secure.string(forKey: Key.anonymousId) != nil }

    /// `$ARAnon:<UUID>`, minted once and kept in the Keychain (survives reinstalls).
    func anonymousId() -> String {
        if let existing = secure.string(forKey: Key.anonymousId), Self.isAnonymous(existing) {
            return existing
        }
        return resetAnonymousId()
    }

    @discardableResult
    func resetAnonymousId() -> String {
        let id = Self.anonymousPrefix + UUID().uuidString
        secure.set(id, forKey: Key.anonymousId)
        return id
    }

    /// The logged-in app user id, or nil while anonymous.
    var loggedInAppUserId: String? {
        get { defaults.string(forKey: Key.appUserId) }
        set { defaults.set(newValue, forKey: Key.appUserId) }
    }

    var currentAppUserId: String { loggedInAppUserId ?? anonymousId() }

    // MARK: - Account tokens (Apple appAccountToken per app user)

    func accountToken(for appUserId: String) -> UUID? {
        guard let raw = (defaults.dictionary(forKey: Key.accountTokens) as? [String: String])?[appUserId] else { return nil }
        return UUID(uuidString: raw)
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

    // MARK: - logIn that still needs to reach the server

    var pendingIdentify: (anonymousId: String, appUserId: String)? {
        get {
            guard let d = defaults.dictionary(forKey: Key.pendingIdentify) as? [String: String],
                  let anon = d["anonymousId"], let user = d["appUserId"] else { return nil }
            return (anon, user)
        }
        set {
            if let newValue {
                defaults.set(["anonymousId": newValue.anonymousId, "appUserId": newValue.appUserId], forKey: Key.pendingIdentify)
            } else {
                defaults.removeObject(forKey: Key.pendingIdentify)
            }
        }
    }

    // MARK: - Cached CustomerInfo (last server answer)

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
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }
}
