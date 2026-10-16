import XCTest
import StoreKit
@testable import AppRefer

final class OfferingsTests: XCTestCase {
    let json = #"{"currentOfferingId":"default","offerings":[{"id":"default","displayName":"Default","metadata":{"nested":[true,null]},"packages":[{"id":"$rc_annual","packageType":"annual","productId":"year"},{"id":"missing-platform"}]}],"placements":{"onboarding":"default","settings":null},"context":{"experimentId":"exp","variantId":"b"},"requestDateMs":1700000000000,"future":true}"#
    func testParsingAliasesUnknownFieldsAndPackageTypes() throws {
        let response = try JSONDecoder().decode(OfferingsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.offerings[0].metadata?["nested"], .array([.bool(true), .null]))
        XCTAssertEqual(AppReferPackageType.resolve(identifier: "$rc_annual", raw: nil), .annual)
        XCTAssertEqual(AppReferPackageType.resolve(identifier: "$ar_two_month", raw: nil), .twoMonth)
        XCTAssertEqual(AppReferPackageType.resolve(identifier: "future", raw: "future"), .custom)
    }
    func testMissingProductsAndPlacementFallback() async throws {
        let response = try JSONDecoder().decode(OfferingsResponse.self, from: Data(json.utf8))
        let offerings = try await response.resolve { ids in XCTAssertEqual(ids, ["year"]); return [] }
        XCTAssertTrue(offerings.current!.availablePackages.isEmpty)
        XCTAssertEqual(offerings.currentOffering(forPlacement: "unknown")?.identifier, "default")
        XCTAssertEqual(offerings.currentOffering(forPlacement: "onboarding")?.identifier, "default")
        XCTAssertNil(offerings.currentOffering(forPlacement: "settings"))
    }
    func testConcurrentCallsShareRequestAndFreshCache() async throws {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let transport = MockBillingTransport.ok(json)
        let engine = env.engine(transport: transport, storeKit: EmptyOfferingStore())
        async let a = engine.offerings(); async let b = engine.offerings()
        _ = try await (a, b)
        _ = try await engine.offerings()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/billing/v1/offerings")
    }
    func testDiskCacheFallbackReresolvesAndSendsKnown() async throws {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let transport = MockBillingTransport.ok(json)
        let engine = env.engine(transport: transport, storeKit: EmptyOfferingStore())
        _ = try await engine.offerings()
        let bucket = transport.requests[0].jsonBody?["bucketId"] as? String
        XCTAssertTrue(bucket?.hasPrefix("$ARAnon:") == true)
        let failed = MockBillingTransport.unreachable()
        let restarted = env.engine(transport: failed, storeKit: EmptyOfferingStore())
        let cached = try await restarted.offerings(policy: .fetchCurrent)
        XCTAssertEqual(cached.current?.identifier, "default")
        XCTAssertEqual(failed.requests.first?.jsonBody?["known"] as? [String: String], ["experimentId":"exp", "variantId":"b"])
    }
    func testNoCacheThrowsBillingError() async {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        do { _ = try await env.engine(transport: MockBillingTransport.unreachable(), storeKit: EmptyOfferingStore()).offerings(); XCTFail("expected failure") }
        catch { XCTAssertTrue(error is AppReferBillingError) }
    }
    func testPurchaseContextSavedInIntentAndPosted() async throws {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "alice"))
        let engine = env.engine(transport: transport, appUserId: "alice")
        let context = PresentedOfferingContext(offeringId: "default", packageId: "$ar_annual", placementId: "onboarding", targetingRuleId: nil, experimentId: "exp", variantId: "b")
        let intent = try await engine.beginPurchase(productId: "pro_yearly", context: context)
        let transaction = StoreTransaction(id: "1", originalId: "1", productId: "pro_yearly", kind: .autoRenewable, purchaseDate: BillingFixtures.now, expirationDate: nil, revocationDate: nil, isUpgraded: false, periodType: .normal, signedTransaction: "jws")
        let update = StoreKitUpdate(verified: transaction, transactionId: "1", finish: {})
        _ = await engine.process(update, initiator: "alice", intent: intent)
        let body = try XCTUnwrap(transport.requests(to: "/api/billing/v1/purchases").first?.jsonBody)
        XCTAssertEqual((body["presentedOfferingContext"] as? [String: String])?["placementId"], "onboarding")
        XCTAssertEqual(body["bucketId"] as? String, intent.bucketId)
    }
    func testEmptyEntitlementMappingsUnlockNothing() {
        XCTAssertEqual(LocalEntitlements.entitlementIds(for: "p", configured: ["p": []], learned: ["p": ["other"]], defaultEntitlement: nil), [])
        XCTAssertEqual(LocalEntitlements.entitlementIds(for: "p", configured: [:], learned: ["p": []], defaultEntitlement: nil), [])
        XCTAssertEqual(LocalEntitlements.entitlementIds(for: "p", configured: [:], learned: [:], defaultEntitlement: nil), ["premium"])
    }
    func testStartupCompletesWhileCachedOfferingProductsAreSuspended() async throws {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let storage = env.storage()
        let user = storage.currentAppUserId!
        let response = try JSONDecoder().decode(OfferingsResponse.self, from: Data(json.utf8))
        storage.saveOfferings(CachedOfferings(response: response, fetchedAt: .distantPast), for: user)
        let transport = MockBillingTransport { request in
            (Data((request.url!.path.hasSuffix("/offerings") ? self.json : BillingFixtures.customerJSON(appUserId: user)).utf8), 200)
        }
        let store = SuspendedOfferingStore()
        await store.pauseNext()
        let engine = env.engine(transport: transport, storeKit: store)
        await engine.start()
        await store.waitUntilPaused()
        XCTAssertFalse(transport.requests(to: "/api/billing/v1/customers").isEmpty)
        await store.release()
    }
    func testForegroundWithoutCacheDoesNotFetchOfferings() async {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let transport = MockBillingTransport.ok(json)
        await env.engine(transport: transport).refreshOfferingsIfStale()
        XCTAssertTrue(transport.requests.isEmpty)
    }
    func testForegroundRefreshesExistingStaleDiskCache() async throws {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let response = try JSONDecoder().decode(OfferingsResponse.self, from: Data(json.utf8))
        let storage = env.storage()
        storage.saveOfferings(CachedOfferings(response: response, fetchedAt: .distantPast), for: storage.currentAppUserId!)
        let transport = MockBillingTransport.ok(json)
        await env.engine(transport: transport).refreshOfferingsIfStale()
        XCTAssertEqual(transport.requests.count, 1)
    }
    func testProductLookupFailurePreservesCachedCatalogue() async throws {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        _ = try await env.engine(transport: MockBillingTransport.ok(json)).offerings()
        let result = try await env.engine(transport: MockBillingTransport.unreachable(), storeKit: FailingOfferingStore()).offerings(policy: .fetchCurrent)
        XCTAssertEqual(result.current?.identifier, "default")
        XCTAssertTrue(result.current!.availablePackages.isEmpty)
    }
    func testUnreadableIdentityThrowsStorageWithoutNetwork() async {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        env.secure.isLocked = true
        let transport = MockBillingTransport.ok(json)
        do { _ = try await env.engine(transport: transport).offerings(); XCTFail("expected storage error") }
        catch { guard case AppReferBillingError.storage = error else { return XCTFail("wrong error: \(error)") } }
        XCTAssertTrue(transport.requests.isEmpty)
    }
    func testBucketSurvivesLogoutAndReinstallAndMigratesDefaults() throws {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let storage = env.storage()
        let legacy = "$ARAnon:legacy"
        env.defaults.set(legacy, forKey: "apprefer_billing_offerings_bucket")
        XCTAssertEqual(storage.offeringsBucketId(), legacy)
        _ = storage.resetAnonymousId()
        env.defaults.removePersistentDomain(forName: env.suiteName)
        XCTAssertEqual(env.storage().offeringsBucketId(), legacy)
    }
    func testBucketWriteFailureDoesNotReturnUnpersistedIdentity() {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        _ = env.storage().anonymousId()
        env.secure.failWrites = true
        XCTAssertNil(env.storage().offeringsBucketId())
    }
    func testQueueMergePreservesAttributionAcrossRedeliveryAndRestore() {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let queue = env.queue()
        let context = PresentedOfferingContext(offeringId: "default", packageId: "annual", placementId: "onboarding", targetingRuleId: nil, experimentId: nil, variantId: nil)
        var entry = PendingPurchase(presentedOfferingContext: context, bucketId: "bucket", transactionId: "tx", productId: "year", appUserId: "alice", appreferId: nil, signedTransaction: "jws", enqueuedAt: Date(), attempts: 0)
        XCTAssertTrue(queue.add(entry))
        entry.presentedOfferingContext = nil; entry.bucketId = nil
        XCTAssertTrue(queue.add(entry))
        entry.restore = true
        XCTAssertTrue(queue.add(entry))
        XCTAssertEqual(env.queue().entries.first?.presentedOfferingContext, context)
        XCTAssertEqual(env.queue().entries.first?.bucketId, "bucket")
    }
    func testFetchCurrentDoesNotJoinCacheResolution() async throws {
        let env = BillingTestEnvironment(); defer { env.cleanUp() }
        let transport = MockBillingTransport.ok(json)
        let store = SuspendedOfferingStore()
        let engine = env.engine(transport: transport, storeKit: store)
        _ = try await engine.offerings()
        await store.pauseNext()
        let cached = Task { try await engine.offerings() }
        await store.waitUntilPaused()
        _ = try await engine.offerings(policy: .fetchCurrent)
        XCTAssertEqual(transport.requests.count, 2)
        await store.release()
        _ = try await cached.value
    }
    func testStorefrontAlpha3Table() { XCTAssertEqual(StorefrontCountry.alpha2("USA"), "US"); XCTAssertEqual(StorefrontCountry.alpha2("GBR"), "GB"); XCTAssertNil(StorefrontCountry.alpha2("ZZZ")) }
}
private struct EmptyOfferingStore: BillingStoreKit {
    func products(_ ids: [String]) async throws -> [Product] { [] }
    func currentEntitlements() async -> [StoreTransaction] { [] }
    func unfinishedTransactions() async -> [StoreKitUpdate] { [] }
    func transactionUpdates() -> AsyncStream<StoreKitUpdate> { AsyncStream { $0.finish() } }
    func sync() async throws {}
}

private struct FailingOfferingStore: BillingStoreKit {
    func products(_ ids: [String]) async throws -> [Product] { throw AppReferBillingError.network("store offline") }
    func currentEntitlements() async -> [StoreTransaction] { [] }
    func unfinishedTransactions() async -> [StoreKitUpdate] { [] }
    func transactionUpdates() -> AsyncStream<StoreKitUpdate> { AsyncStream { $0.finish() } }
    func sync() async throws {}
}
private actor SuspendedOfferingStore: BillingStoreKit {
    var shouldPause = false
    var continuation: CheckedContinuation<Void, Never>?
    func pauseNext() { shouldPause = true }
    func waitUntilPaused() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func products(_ ids: [String]) async throws -> [Product] {
        if shouldPause { shouldPause = false; await withCheckedContinuation { continuation = $0 } }
        return []
    }
    func currentEntitlements() async -> [StoreTransaction] { [] }
    func unfinishedTransactions() async -> [StoreKitUpdate] { [] }
    nonisolated func transactionUpdates() -> AsyncStream<StoreKitUpdate> { AsyncStream { $0.finish() } }
    func sync() async throws {}
}
