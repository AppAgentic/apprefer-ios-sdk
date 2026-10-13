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
    let periodType: BillingPeriodType
    /// StoreKit 2 `jwsRepresentation`, sent to AppRefer as `signedTransaction`.
    let signedTransaction: String
}

/// One transaction delivered by StoreKit (purchase, update or unfinished).
struct StoreKitUpdate: Sendable {
    /// Nil when StoreKit could not verify the signature.
    let verified: StoreTransaction?
    let transactionId: String
    let finish: @Sendable () async -> Void
}

/// StoreKit behind a protocol so the engine can be tested with fakes.
protocol BillingStoreKit: Sendable {
    /// Verified `Transaction.currentEntitlements`.
    func currentEntitlements() async -> [StoreTransaction]
    /// `Transaction.unfinished`, e.g. after a crash between purchase and finish.
    func unfinishedTransactions() async -> [StoreKitUpdate]
    /// `Transaction.updates`: renewals, Ask to Buy approvals, purchases on other devices.
    func transactionUpdates() -> AsyncStream<StoreKitUpdate>
    /// `AppStore.sync()`.
    func sync() async throws
}

@available(iOS 15.0, macOS 12.0, *)
struct LiveBillingStoreKit: BillingStoreKit {
    func currentEntitlements() async -> [StoreTransaction] {
        var result: [StoreTransaction] = []
        for await verification in Transaction.currentEntitlements {
            if case .verified(let transaction) = verification {
                result.append(Self.map(transaction, jws: verification.jwsRepresentation))
            }
        }
        return result
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
                finish: { await transaction.finish() }
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
            signedTransaction: jws
        )
    }

    private static func periodType(of t: Transaction) -> BillingPeriodType {
        if #available(iOS 17.2, macOS 14.2, tvOS 17.2, watchOS 10.2, visionOS 1.1, *) {
            guard let offer = t.offer else { return .normal }
            if offer.type == .introductory { return offer.paymentMode == .freeTrial ? .trial : .intro }
            return .promotional
        }
        switch t.offerType {
        case .some(.introductory): return .intro
        case .some: return .promotional
        case .none: return .normal
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
        if let ids = configured[productId], !ids.isEmpty { return ids }
        if let ids = learned[productId], !ids.isEmpty { return ids }
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
