import Foundation
import StoreKit

/// The parts of a StoreKit 2 transaction billing needs, so the logic is testable
/// without StoreKit (whose `Transaction` can't be constructed in tests).
struct StoreTransaction: Sendable, Equatable {
    enum Kind: String, Sendable { case autoRenewable, nonRenewable, consumable, nonConsumable }

    let id: String
    let originalId: String
    let productId: String
    let kind: Kind
    let purchaseDate: Date
    let expirationDate: Date?
    let revocationDate: Date?
    let isUpgraded: Bool
    var periodType: BillingPeriodType
    /// StoreKit 2 `jwsRepresentation`, sent to AppRefer as `signedTransaction`.
    let signedTransaction: String
    /// The `appAccountToken` the purchase was tagged with (the buyer's AppRefer account token).
    var appAccountToken: UUID? = nil

    /// A later transaction in a subscription chain (`originalId != id`). Renewals never
    /// match or consume a purchase intent: they belong to the original purchase's owner.
    var isRenewal: Bool { originalId != id }
    var environment: BillingEnvironment? { BillingEnvironment.localTransaction(signedTransaction) }
}

/// One transaction delivered by StoreKit (purchase, update or unfinished).
struct StoreKitUpdate: Sendable {
    /// Nil when StoreKit could not verify the signature.
    let verified: StoreTransaction?
    let transactionId: String
    let finish: @Sendable () async -> Void
    /// What an unverified transaction claims (its JWS included), kept for the rejected list.
    var unverifiedPayload: StoreTransaction? = nil
}

/// StoreKit behind a protocol so the engine can be tested with fakes.
protocol BillingStoreKit: Sendable {
    func products(_ ids: [String]) async throws -> [Product]
    func storefrontCountry() async -> String?
    /// Verified `Transaction.currentEntitlements`.
    func currentEntitlements() async -> [StoreTransaction]
    /// `Transaction.unfinished`, e.g. after a crash between purchase and finish.
    func unfinishedTransactions() async -> [StoreKitUpdate]
    /// `Transaction.updates`: renewals, Ask to Buy approvals, purchases on other devices.
    func transactionUpdates() -> AsyncStream<StoreKitUpdate>
    /// `AppStore.sync()`.
    func sync() async throws
}

extension BillingStoreKit {
    func products(_ ids: [String]) async throws -> [Product] { try await Product.products(for: ids) }
    func storefrontCountry() async -> String? { nil }
}
struct LiveBillingStoreKit: BillingStoreKit {
    func storefrontCountry() async -> String? {
        guard let storefront = await Storefront.current else { return nil }
        return StorefrontCountry.alpha2(storefront.countryCode)
    }
    func currentEntitlements() async -> [StoreTransaction] {
        var result: [StoreTransaction] = []
        for await verification in Transaction.currentEntitlements {
            if case .verified(let transaction) = verification {
                var mapped = Self.map(transaction, jws: verification.jwsRepresentation)
                if mapped.periodType == .intro, await Self.introOfferIsFreeTrial(productId: mapped.productId) {
                    mapped.periodType = .trial
                }
                result.append(mapped)
            }
        }
        return result
    }

    private actor IntroOfferCache {
        private var freeTrialByProduct: [String: Bool] = [:]
        func get(_ productId: String) -> Bool? { freeTrialByProduct[productId] }
        func set(_ productId: String, _ value: Bool) { freeTrialByProduct[productId] = value }
    }
    private static let introOfferCache = IntroOfferCache()

    /// Before iOS 17.2 a transaction doesn't say how its intro offer was paid. A product
    /// has one introductory offer, so the product's offer tells whether it was a free trial.
    private static func introOfferIsFreeTrial(productId: String) async -> Bool {
        if #available(iOS 17.2, macOS 14.2, tvOS 17.2, watchOS 10.2, visionOS 1.1, *) { return false }
        if let cached = await introOfferCache.get(productId) { return cached }
        guard let product = try? await Product.products(for: [productId]).first else { return false }
        let isFreeTrial = product.subscription?.introductoryOffer?.paymentMode == .freeTrial
        await introOfferCache.set(productId, isFreeTrial)
        return isFreeTrial
    }

    func unfinishedTransactions() async -> [StoreKitUpdate] {
        var result: [StoreKitUpdate] = []
        for await verification in Transaction.unfinished {
            result.append(Self.update(from: verification))
        }
        return result
    }

    func transactionUpdates() -> AsyncStream<StoreKitUpdate> {
        AsyncStream { continuation in
            let task = Task.detached {
                for await verification in Transaction.updates {
                    continuation.yield(Self.update(from: verification))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    static func update(from verification: VerificationResult<Transaction>) -> StoreKitUpdate {
        switch verification {
        case .verified(let transaction):
            return StoreKitUpdate(
                verified: map(transaction, jws: verification.jwsRepresentation),
                transactionId: String(transaction.id),
                finish: { await transaction.finish() }
            )
        case .unverified(let transaction, _):
            return StoreKitUpdate(
                verified: nil,
                transactionId: String(transaction.id),
                finish: { await transaction.finish() },
                unverifiedPayload: map(transaction, jws: verification.jwsRepresentation)
            )
        }
    }

    static func map(_ t: Transaction, jws: String) -> StoreTransaction {
        let kind: StoreTransaction.Kind
        switch t.productType {
        case .autoRenewable: kind = .autoRenewable
        case .nonRenewable: kind = .nonRenewable
        case .consumable: kind = .consumable
        default: kind = .nonConsumable
        }
        return StoreTransaction(
            id: String(t.id),
            originalId: String(t.originalID),
            productId: t.productID,
            kind: kind,
            purchaseDate: t.purchaseDate,
            expirationDate: t.expirationDate,
            revocationDate: t.revocationDate,
            isUpgraded: t.isUpgraded,
            periodType: periodType(of: t),
            signedTransaction: jws,
            appAccountToken: t.appAccountToken
        )
    }

    private static func periodType(of t: Transaction) -> BillingPeriodType {
        if #available(iOS 17.2, macOS 14.2, tvOS 17.2, watchOS 10.2, visionOS 1.1, *) {
            guard let offer = t.offer else { return .normal }
            if offer.type == .introductory { return offer.paymentMode == .freeTrial ? .trial : .intro }
            return .promotional
        }
        let offer: LegacyOffer
        switch t.offerType {
        case .some(.introductory): offer = .introductory
        case .some: offer = .promotional
        case .none: offer = .none
        }
        return legacyPeriodType(offer: offer, signedPayload: t.jsonRepresentation)
    }

    enum LegacyOffer { case none, introductory, promotional }

    /// iOS 15–17.1: the signed payload's `offerDiscountType` (`FREE_TRIAL`, `PAY_AS_YOU_GO`,
    /// `PAY_UP_FRONT`) tells a free trial apart from a paid intro when Apple includes it;
    /// otherwise `currentEntitlements` checks the product's intro offer.
    static func legacyPeriodType(offer: LegacyOffer, signedPayload: Data) -> BillingPeriodType {
        switch offer {
        case .none: return .normal
        case .promotional: return .promotional
        case .introductory:
            let payload = (try? JSONSerialization.jsonObject(with: signedPayload)) as? [String: Any]
            return payload?["offerDiscountType"] as? String == "FREE_TRIAL" ? .trial : .intro
        }
    }
}

/// Device-side entitlement logic: the outage fallback.
enum LocalEntitlements {
    /// Entitlement ids for a product: the configured map, then what the server has told
    /// us before, then the default (the server's own default is `premium`).
    static func entitlementIds(
        for productId: String,
        configured: [String: [String]],
        learned: [String: [String]],
        defaultEntitlement: String?
    ) -> [String] {
        if let ids = configured[productId] { return ids }
        if let ids = learned[productId] { return ids }
        return [defaultEntitlement ?? "premium"]
    }

    /// Entitlements granted by verified StoreKit transactions: not revoked, not
    /// upgraded away, not expired, not consumable.
    static func compute(
        transactions: [StoreTransaction],
        configured: [String: [String]],
        learned: [String: [String]],
        defaultEntitlement: String?,
        now: Date
    ) -> (entitlements: [String: AppReferEntitlementInfo], activeSubscriptions: Set<String>) {
        var entitlements: [String: AppReferEntitlementInfo] = [:]
        var activeSubscriptions = Set<String>()

        for t in transactions {
            if t.kind == .consumable || t.revocationDate != nil || t.isUpgraded { continue }
            if let expires = t.expirationDate, expires <= now { continue }
            if t.kind == .autoRenewable { activeSubscriptions.insert(t.productId) }

            for id in entitlementIds(for: t.productId, configured: configured, learned: learned, defaultEntitlement: defaultEntitlement) {
                let info = AppReferEntitlementInfo(
                    identifier: id,
                    isActive: true,
                    productIdentifier: t.productId,
                    store: .appStore,
                    expirationDate: t.expirationDate,
                    // StoreKit's renewal status needs another call; unknown here.
                    willRenew: false,
                    periodType: t.periodType,
                    state: .active,
                    subscriptionKey: t.originalId
                )
                if let current = entitlements[id], !info.beats(current) { continue }
                entitlements[id] = info
            }
        }
        return (entitlements, activeSubscriptions)
    }

    /// Merges device entitlements into a server snapshot (fresh or cached). Per
    /// entitlement the server rule applies: active beats inactive, later expiry wins.
    static func merge(
        server: AppReferCustomerInfo?,
        local: (entitlements: [String: AppReferEntitlementInfo], activeSubscriptions: Set<String>),
        appUserId: String,
        now: Date,
        source: AppReferCustomerInfo.Source
    ) -> AppReferCustomerInfo {
        var all = server?.entitlements.all ?? [:]
        for (id, info) in local.entitlements {
            if let current = all[id], !info.beats(current) { continue }
            all[id] = info
        }
        return AppReferCustomerInfo(
            appUserId: appUserId,
            entitlements: EntitlementInfos(all),
            activeSubscriptions: (server?.activeSubscriptions ?? []).union(local.activeSubscriptions),
            requestDate: now,
            source: source
        )
    }
}

extension BillingEngine {
    /// Whether a `Product.purchase` error means no transaction can follow. Network,
    /// system and unknown errors don't: the purchase may still arrive, so its intent stays.
    static func endsPurchase(_ error: Error) -> Bool {
        if let error = error as? Product.PurchaseError {
            switch error {
            case .productUnavailable, .purchaseNotAllowed, .ineligibleForOffer,
                 .invalidOfferIdentifier, .invalidOfferPrice, .invalidOfferSignature,
                 .missingOfferParameters, .invalidQuantity:
                return true
            default:
                // Newer cases (e.g. payment-method binding) aren't known to end it: keep.
                return false
            }
        }
        switch error as? StoreKitError {
        case .userCancelled?, .notAvailableInStorefront?, .notEntitled?: return true
        default: return false
        }
    }
}
