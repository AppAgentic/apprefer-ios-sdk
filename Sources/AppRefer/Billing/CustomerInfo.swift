import Foundation

/// The customer's entitlements as AppRefer Billing sees them.
///
/// Mirrors RevenueCat's `CustomerInfo`, so `customerInfo.entitlements["premium"]?.isActive`
/// works the same way. Decoded from the server's `CustomerInfo` JSON
/// (`web/lib/billing/types.ts` in the AppRefer repo).
///
/// `CustomerInfo` is also available as `AppReferCustomerInfo`, for files that import
/// both AppRefer and RevenueCat during a migration.
public typealias CustomerInfo = AppReferCustomerInfo

/// One entitlement (for example `premium`). Also available as `AppReferEntitlementInfo`.
public typealias EntitlementInfo = AppReferEntitlementInfo

public struct AppReferCustomerInfo: Sendable, Equatable {
    /// Where this snapshot came from.
    public enum Source: String, Codable, Sendable {
        /// Returned by the AppRefer server just now.
        case server
        /// The last server response, re-checked against the clock.
        case cache
        /// AppRefer was unreachable or refused the request; entitlements come from
        /// StoreKit's verified `Transaction.currentEntitlements`, merged with the cache.
        case localFallback
    }

    public let environment: BillingEnvironment?
    public let appUserId: String
    public let entitlements: EntitlementInfos
    /// Product ids of auto-renewing subscriptions that currently grant access.
    public let activeSubscriptions: Set<String>
    /// When the snapshot was computed.
    public let requestDate: Date
    public let source: Source

    public init(
        appUserId: String,
        entitlements: EntitlementInfos,
        activeSubscriptions: Set<String>,
        requestDate: Date,
        source: Source,
        environment: BillingEnvironment? = nil
    ) {
        self.environment = environment
        self.appUserId = appUserId
        self.entitlements = entitlements
        self.activeSubscriptions = activeSubscriptions
        self.requestDate = requestDate
        self.source = source
    }

    /// True when any entitlement is active.
    public var hasActiveEntitlement: Bool { !entitlements.active.isEmpty }

    func with(source: Source) -> AppReferCustomerInfo {
        AppReferCustomerInfo(
            appUserId: appUserId,
            entitlements: entitlements,
            activeSubscriptions: activeSubscriptions,
            requestDate: requestDate,
            source: source,
            environment: environment
        )
    }

    /// Same user, entitlements and subscriptions (ignores request date and source).
    func hasSameContent(as other: AppReferCustomerInfo) -> Bool {
        environment == other.environment && appUserId == other.appUserId
            && entitlements == other.entitlements
            && activeSubscriptions == other.activeSubscriptions
    }

    /// Re-checks a cached snapshot against the clock, so an expired subscription
    /// never stays unlocked from an old cache. Grace periods keep the server's verdict.
    func reevaluated(at now: Date) -> AppReferCustomerInfo {
        var all: [String: AppReferEntitlementInfo] = [:]
        var activeSubs = activeSubscriptions
        for (id, ent) in entitlements.all {
            if ent.isActive, ent.state != .inGracePeriod,
               let expires = ent.expirationDate, expires <= now {
                all[id] = ent.expired()
                activeSubs.remove(ent.productIdentifier)
            } else {
                all[id] = ent
            }
        }
        return AppReferCustomerInfo(
            appUserId: appUserId,
            entitlements: EntitlementInfos(all),
            activeSubscriptions: activeSubs,
            requestDate: now,
            source: .cache,
            environment: environment
        )
    }
}

extension AppReferCustomerInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case environment, appUserId, entitlements, activeSubscriptions, requestDateMs, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        environment = try c.decodeIfPresent(BillingEnvironment.self, forKey: .environment)
        appUserId = try c.decode(String.self, forKey: .appUserId)
        entitlements = (try? c.decode(EntitlementInfos.self, forKey: .entitlements)) ?? EntitlementInfos([:])
        activeSubscriptions = Set((try? c.decode([String].self, forKey: .activeSubscriptions)) ?? [])
        let ms = (try? c.decode(Double.self, forKey: .requestDateMs)) ?? Date().timeIntervalSince1970 * 1000
        requestDate = Date(timeIntervalSince1970: ms / 1000)
        source = (try? c.decode(Source.self, forKey: .source)) ?? .server
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(environment, forKey: .environment)
        try c.encode(appUserId, forKey: .appUserId)
        try c.encode(entitlements, forKey: .entitlements)
        try c.encode(activeSubscriptions.sorted(), forKey: .activeSubscriptions)
        try c.encode((requestDate.timeIntervalSince1970 * 1000).rounded(), forKey: .requestDateMs)
        try c.encode(source, forKey: .source)
    }
}

/// Entitlements keyed by id. `entitlements["premium"]?.isActive`.
public struct EntitlementInfos: Sendable, Equatable, Codable {
    public let all: [String: AppReferEntitlementInfo]

    public init(_ all: [String: AppReferEntitlementInfo]) {
        self.all = all
    }

    public subscript(_ identifier: String) -> AppReferEntitlementInfo? { all[identifier] }

    /// Only the entitlements that currently grant access.
    public var active: [String: AppReferEntitlementInfo] { all.filter { $0.value.isActive } }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: AppReferEntitlementInfo].self)
        var fixed: [String: AppReferEntitlementInfo] = [:]
        for (key, ent) in raw {
            fixed[key] = ent.identifier.isEmpty ? ent.withIdentifier(key) : ent
        }
        all = fixed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(all)
    }
}

public struct AppReferEntitlementInfo: Sendable, Equatable {
    public let identifier: String
    public let isActive: Bool
    public let productIdentifier: String
    public let store: BillingStore
    /// Nil for lifetime (non-consumable) purchases.
    public let expirationDate: Date?
    public let willRenew: Bool
    public let periodType: BillingPeriodType
    public let state: BillingSubscriptionState
    /// Apple original transaction id / Google purchase-chain key.
    public let subscriptionKey: String

    public init(
        identifier: String,
        isActive: Bool,
        productIdentifier: String,
        store: BillingStore,
        expirationDate: Date?,
        willRenew: Bool,
        periodType: BillingPeriodType,
        state: BillingSubscriptionState,
        subscriptionKey: String
    ) {
        self.identifier = identifier
        self.isActive = isActive
        self.productIdentifier = productIdentifier
        self.store = store
        self.expirationDate = expirationDate
        self.willRenew = willRenew
        self.periodType = periodType
        self.state = state
        self.subscriptionKey = subscriptionKey
    }

    func withIdentifier(_ id: String) -> AppReferEntitlementInfo {
        AppReferEntitlementInfo(
            identifier: id, isActive: isActive, productIdentifier: productIdentifier, store: store,
            expirationDate: expirationDate, willRenew: willRenew, periodType: periodType,
            state: state, subscriptionKey: subscriptionKey
        )
    }

    func expired() -> AppReferEntitlementInfo {
        AppReferEntitlementInfo(
            identifier: identifier, isActive: false, productIdentifier: productIdentifier, store: store,
            expirationDate: expirationDate, willRenew: false, periodType: periodType,
            state: .expired, subscriptionKey: subscriptionKey
        )
    }

    /// Server rule for choosing between two sources of one entitlement:
    /// active beats inactive, then the later expiry (nil = lifetime) wins.
    func beats(_ other: AppReferEntitlementInfo) -> Bool {
        if isActive != other.isActive { return isActive }
        let a = expirationDate ?? .distantFuture
        let b = other.expirationDate ?? .distantFuture
        return a > b
    }
}

extension AppReferEntitlementInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case isActive
        case productIdentifier = "productId"
        case store
        case expirationDate = "expiresAtMs"
        case willRenew, periodType, state, subscriptionKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = (try? c.decode(String.self, forKey: .identifier)) ?? ""
        isActive = (try? c.decode(Bool.self, forKey: .isActive)) ?? false
        productIdentifier = (try? c.decode(String.self, forKey: .productIdentifier)) ?? ""
        store = (try? c.decode(BillingStore.self, forKey: .store)) ?? .unknown
        if let ms = try? c.decode(Double.self, forKey: .expirationDate) {
            expirationDate = Date(timeIntervalSince1970: ms / 1000)
        } else {
            expirationDate = nil
        }
        willRenew = (try? c.decode(Bool.self, forKey: .willRenew)) ?? false
        periodType = (try? c.decode(BillingPeriodType.self, forKey: .periodType)) ?? .unknown
        state = (try? c.decode(BillingSubscriptionState.self, forKey: .state)) ?? .unknown
        subscriptionKey = (try? c.decode(String.self, forKey: .subscriptionKey)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identifier, forKey: .identifier)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(productIdentifier, forKey: .productIdentifier)
        try c.encode(store, forKey: .store)
        if let expirationDate {
            try c.encode((expirationDate.timeIntervalSince1970 * 1000).rounded(), forKey: .expirationDate)
        } else {
            try c.encodeNil(forKey: .expirationDate)
        }
        try c.encode(willRenew, forKey: .willRenew)
        try c.encode(periodType, forKey: .periodType)
        try c.encode(state, forKey: .state)
        try c.encode(subscriptionKey, forKey: .subscriptionKey)
    }
}

public enum BillingStore: String, Sendable, Codable {
    case appStore = "app_store"
    case playStore = "play_store"
    case unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum BillingPeriodType: String, Sendable, Codable {
    case trial, intro, normal, promotional, unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum BillingSubscriptionState: String, Sendable, Codable {
    case active
    /// Billing failed but the store is still retrying; access continues.
    case inGracePeriod = "in_grace_period"
    /// Billing failed; no access.
    case inBillingRetry = "in_billing_retry"
    case paused, expired, revoked, unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// Server response for the customers/purchases/identify endpoints.
struct BillingCustomerResponse: Decodable, Sendable {
    let info: AppReferCustomerInfo
    let accountToken: String?
    var legacyAppAccountToken: String? = nil

    private enum Keys: String, CodingKey { case accountToken, legacyAppAccountToken }

    init(info: AppReferCustomerInfo, accountToken: String?) {
        self.info = info
        self.accountToken = accountToken
    }

    init(from decoder: Decoder) throws {
        info = try AppReferCustomerInfo(from: decoder).with(source: .server)
        accountToken = try? decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .accountToken)
        legacyAppAccountToken = try? decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .legacyAppAccountToken)
    }
}
