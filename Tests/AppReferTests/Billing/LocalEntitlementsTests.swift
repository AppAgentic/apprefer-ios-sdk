import XCTest
@testable import AppRefer

final class LocalEntitlementsTests: XCTestCase {
    private let now = BillingFixtures.now

    private func compute(
        _ transactions: [StoreTransaction],
        configured: [String: [String]] = [:],
        learned: [String: [String]] = [:],
        defaultEntitlement: String? = nil
    ) -> (entitlements: [String: AppReferEntitlementInfo], activeSubscriptions: Set<String>) {
        LocalEntitlements.compute(
            transactions: transactions, configured: configured, learned: learned,
            defaultEntitlement: defaultEntitlement, now: now
        )
    }

    func testActiveSubscriptionUnlocksMappedEntitlements() throws {
        let result = compute([BillingFixtures.transaction()], configured: ["pro_yearly": ["premium", "coach"]])
        XCTAssertEqual(Set(result.entitlements.keys), ["premium", "coach"])
        let premium = try XCTUnwrap(result.entitlements["premium"])
        XCTAssertTrue(premium.isActive)
        XCTAssertEqual(premium.productIdentifier, "pro_yearly")
        XCTAssertEqual(premium.store, .appStore)
        XCTAssertEqual(premium.state, .active)
        XCTAssertEqual(premium.subscriptionKey, "orig-2000000000000001")
        XCTAssertEqual(result.activeSubscriptions, ["pro_yearly"])
    }

    func testExpiredRevokedUpgradedAndConsumablesGrantNothing() {
        let result = compute([
            BillingFixtures.transaction(id: "1", expires: now.addingTimeInterval(-1)),
            BillingFixtures.transaction(id: "2", revoked: now.addingTimeInterval(-60)),
            BillingFixtures.transaction(id: "3", upgraded: true),
            BillingFixtures.transaction(id: "4", productId: "coins", kind: .consumable, expires: nil),
        ])
        XCTAssertTrue(result.entitlements.isEmpty)
        XCTAssertTrue(result.activeSubscriptions.isEmpty)
    }

    func testLifetimePurchaseUnlocksWithoutExpiry() {
        let result = compute(
            [BillingFixtures.transaction(productId: "pro_lifetime", kind: .nonConsumable, expires: nil)],
            configured: ["pro_lifetime": ["premium"]]
        )
        XCTAssertEqual(result.entitlements["premium"]?.isActive, true)
        XCTAssertNil(result.entitlements["premium"]?.expirationDate)
        XCTAssertTrue(result.activeSubscriptions.isEmpty, "only auto-renewables are subscriptions")
    }

    func testMappingPrecedenceConfiguredThenLearnedThenDefault() {
        XCTAssertEqual(
            LocalEntitlements.entitlementIds(for: "p", configured: ["p": ["a"]], learned: ["p": ["b"]], defaultEntitlement: "c"),
            ["a"]
        )
        XCTAssertEqual(
            LocalEntitlements.entitlementIds(for: "p", configured: [:], learned: ["p": ["b"]], defaultEntitlement: "c"),
            ["b"]
        )
        XCTAssertEqual(LocalEntitlements.entitlementIds(for: "p", configured: [:], learned: [:], defaultEntitlement: "c"), ["c"])
        XCTAssertEqual(
            LocalEntitlements.entitlementIds(for: "p", configured: [:], learned: [:], defaultEntitlement: nil),
            ["premium"], "same default as the server"
        )
    }

    func testLaterExpiryWinsWithinOneEntitlement() {
        let result = compute([
            BillingFixtures.transaction(id: "1", productId: "monthly", expires: now.addingTimeInterval(100)),
            BillingFixtures.transaction(id: "2", productId: "yearly", expires: now.addingTimeInterval(1000)),
        ])
        XCTAssertEqual(result.entitlements["premium"]?.productIdentifier, "yearly")
        XCTAssertEqual(result.activeSubscriptions, ["monthly", "yearly"])
    }

    func testMergeLocalActiveOverridesCachedInactive() throws {
        let cached = try JSONDecoder().decode(
            AppReferCustomerInfo.self,
            from: Data(BillingFixtures.customerJSON(appUserId: "u", isActive: false, expiresAtMs: 1000).utf8)
        )
        let merged = LocalEntitlements.merge(
            server: cached, local: compute([BillingFixtures.transaction()]),
            appUserId: "u", now: now, source: .localFallback
        )
        XCTAssertEqual(merged.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(merged.source, .localFallback)
        XCTAssertEqual(merged.activeSubscriptions, ["pro_yearly"])
    }

    func testMergeKeepsCachedEntitlementsStoreKitDoesNotKnow() throws {
        // e.g. a web (Stripe) or Android purchase known only to the server.
        let cached = try JSONDecoder().decode(
            AppReferCustomerInfo.self,
            from: Data(BillingFixtures.customerJSON(appUserId: "u", entitlement: "web_pro", productId: "stripe_pro").utf8)
        )
        let merged = LocalEntitlements.merge(
            server: cached, local: compute([]), appUserId: "u", now: now, source: .localFallback
        )
        XCTAssertEqual(merged.entitlements["web_pro"]?.isActive, true)
    }
}
