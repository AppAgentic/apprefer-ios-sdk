import StoreKit
import XCTest
@testable import AppRefer

/// The rules all four SDKs share (Astra final check, Oct 2026): (a) the rejected archive
/// is never capped or evicted; (b) renewals never match or consume an intent; (c) untagged
/// new purchases match the oldest intent for the product, tagged or not; (d) undecodable
/// intents are quarantined behind a persisted marker that defers untagged purchases for up
/// to 48 hours; (e) intents leave only on definitive outcomes.
final class BillingSharedRulesTests: XCTestCase {
    private var env: BillingTestEnvironment!
    private let purchasesPath = "/api/billing/v1/purchases"

    override func setUp() {
        super.setUp()
        env = BillingTestEnvironment()
    }

    override func tearDown() {
        env.cleanUp()
        super.tearDown()
    }

    private var intentsURL: URL { env.directory.appendingPathComponent("purchase_intents.json") }
    private var markerURL: URL { env.directory.appendingPathComponent("purchase_intents.lost.json") }
    private var rejectedURL: URL { env.directory.appendingPathComponent("rejected_purchases.json") }

    private func original(id: String = "3000000000000001", at date: Date = BillingFixtures.now, token: UUID? = nil) -> StoreTransaction {
        StoreTransaction(
            id: id, originalId: id, productId: "pro_yearly", kind: .autoRenewable,
            purchaseDate: date, expirationDate: date.addingTimeInterval(86_400), revocationDate: nil,
            isUpgraded: false, periodType: .normal, signedTransaction: "jws.\(id).sig", appAccountToken: token
        )
    }

    private func entry(_ id: String) -> AppReferRejectedPurchase {
        AppReferRejectedPurchase(
            transactionId: id, productId: "p", appUserId: "u", appreferId: nil, signedTransaction: "jws.\(id)",
            accountToken: nil, kind: nil, verifiedByStoreKit: true, reason: "r", rejectedAt: BillingFixtures.now
        )
    }

    // MARK: (a)

    func testRejectedArchiveHasNoCapAndShrinksOnlyWhenRecorded() {
        let log = RejectedPurchaseLog(fileURL: rejectedURL)
        for i in 0..<250 { XCTAssertTrue(log.add(entry("t\(i)"))) }
        XCTAssertEqual(RejectedPurchaseLog(fileURL: rejectedURL).entries.count, 250, "nothing evicted")
        log.remove(transactionId: "t0") // AppRefer recorded it
        XCTAssertEqual(RejectedPurchaseLog(fileURL: rejectedURL).entries.count, 249)
        XCTAssertEqual(RejectedPurchaseLog(fileURL: rejectedURL).entries.first?.transactionId, "t1")
    }

    // MARK: (b)

    func testRenewalNeitherMatchesNorConsumesASavedIntent() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let intent = try await env.engine(transport: MockBillingTransport.unreachable(), storage: storage)
            .beginPurchase(productId: "pro_yearly")

        storage.loggedInAppUserId = "user_b"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_b"))
        let engine = env.engine(transport: transport, storage: storage)
        let renewal = BillingFixtures.transaction() // originalId != id
        _ = await engine.process(BillingFixtures.update(renewal, counter: FinishCounter()))
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["appUserId"] as? String, "user_b")
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [intent], "intent left for its own purchase")
    }

    // MARK: (c)

    func testUntaggedPurchaseMatchesOldestIntentEvenIfItHadAToken() {
        let store = PurchaseIntentStore(fileURL: intentsURL)
        let tagged = PurchaseIntent(appUserId: "user_a", productId: "pro_yearly", accountToken: BillingFixtures.accountToken,
                                    startedAt: BillingFixtures.now.addingTimeInterval(-600))
        let untagged = PurchaseIntent(appUserId: "user_c", productId: "pro_yearly", accountToken: nil,
                                      startedAt: BillingFixtures.now.addingTimeInterval(-60))
        let otherProduct = PurchaseIntent(appUserId: "user_d", productId: "pro_monthly", accountToken: nil,
                                          startedAt: BillingFixtures.now.addingTimeInterval(-6000))
        XCTAssertTrue(store.add(untagged))
        XCTAssertTrue(store.add(tagged))
        XCTAssertTrue(store.add(otherProduct))
        XCTAssertEqual(store.match(original()), .found(tagged))
    }

    // MARK: (d)

    func testMalformedIntentsAreQuarantinedBehindAMarkerAndDeferUntaggedPurchasesFor48Hours() async throws {
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: intentsURL)
        let clock = TestClock()
        let storage = env.storage()
        storage.loggedInAppUserId = "user_b"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_b"))
        let engine = env.engine(transport: transport, storage: storage, now: { clock.now })

        XCTAssertFalse(FileManager.default.fileExists(atPath: intentsURL.path), "bad file moved aside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "loss persisted")

        let counter = FinishCounter()
        let purchase = original(at: clock.now)
        _ = await engine.process(BillingFixtures.update(purchase, counter: counter))
        XCTAssertEqual(counter.count, 0, "store purchase left open")
        XCTAssertTrue(transport.requests(to: purchasesPath).isEmpty, "not given to the current user yet")

        // The marker survives a restart; the purchase still waits.
        let restarted = env.engine(transport: transport, storage: storage, now: { clock.now })
        _ = await restarted.process(BillingFixtures.update(purchase, counter: counter))
        XCTAssertEqual(counter.count, 0)
        _ = await restarted.customerInfo(policy: .cachedOrFetched) // foreground retry
        XCTAssertTrue(transport.requests(to: purchasesPath).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        // After 48 hours it goes to whoever is signed in, with a support note if refused.
        clock.advance(PurchaseIntentStore.lostIntentsWait + 1)
        transport.setHandler { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"bad"}"#.utf8), 400) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_b").utf8), 200)
        }
        _ = await restarted.customerInfo(policy: .cachedOrFetched)
        XCTAssertEqual(transport.requests(to: purchasesPath).map { $0.jsonBody?["appUserId"] as? String }, ["user_b"])
        XCTAssertEqual(counter.count, 1)
        let archived = try XCTUnwrap(RejectedPurchaseLog(fileURL: rejectedURL).entries.first)
        XCTAssertNotNil(archived.supportNote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path), "cleared: nothing deferred")
    }

    func testIntentsLostMarkerClearsOnlyWhenNothingWaitsAndItIs48HoursOld() async throws {
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        try Data("[{]".utf8).write(to: intentsURL)
        let clock = TestClock()
        let storage = env.storage()
        storage.loggedInAppUserId = "user_b"
        let engine = env.engine(transport: MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_b")),
                                storage: storage, now: { clock.now })
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        await engine.start() // no unfinished transactions
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "kept: a slow Ask to Buy purchase may still arrive")

        clock.advance(PurchaseIntentStore.lostIntentsWait)
        _ = await engine.customerInfo(policy: .cachedOrFetched) // foreground
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testLostIntentsWaitStartsAtTheEarlierOfPurchaseAndLoss() async throws {
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: intentsURL)
        let clock = TestClock()
        let storage = env.storage()
        storage.loggedInAppUserId = "user_b"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_b"))
        let engine = env.engine(transport: transport, storage: storage, now: { clock.now })
        // Bought 47 hours before the intents were found lost.
        let purchase = original(at: clock.now.addingTimeInterval(-47 * 3600))
        let counter = FinishCounter()
        _ = await engine.process(BillingFixtures.update(purchase, counter: counter))
        XCTAssertTrue(transport.requests(to: purchasesPath).isEmpty, "held")

        // 48 hours after the purchase (one after the loss): sent.
        clock.advance(3600)
        _ = await engine.customerInfo(policy: .cachedOrFetched)
        XCTAssertEqual(transport.requests(to: purchasesPath).map { $0.jsonBody?["appUserId"] as? String }, ["user_b"])
        XCTAssertEqual(counter.count, 1)
    }

    func testMalformedIntentsStayInPlaceWhenTheMarkerCantBeSaved() {
        let intents = FlakyPendingPurchaseStore()
        intents.data = Data("garbage".utf8)
        let marker = FlakyPendingPurchaseStore()
        marker.failWrites = true
        let store = PurchaseIntentStore(store: intents, lostMarker: marker)
        XCTAssertNil(intents.quarantined, "not moved aside without the marker")
        XCTAssertNil(store.intents, "unreadable: deliveries defer")
        XCTAssertEqual(store.match(original()), .unreadable)

        marker.failWrites = false
        XCTAssertEqual(store.intents, [])
        XCTAssertEqual(intents.quarantined, Data("garbage".utf8))
        guard case .lost = store.match(original()) else { return XCTFail("untagged purchases wait while intents are lost") }
    }

    // MARK: (e)

    func testOnlyDefinitivePurchaseErrorsDropTheIntent() {
        XCTAssertTrue(BillingEngine.endsPurchase(StoreKitError.userCancelled))
        XCTAssertTrue(BillingEngine.endsPurchase(StoreKitError.notEntitled))
        XCTAssertTrue(BillingEngine.endsPurchase(Product.PurchaseError.productUnavailable))
        XCTAssertFalse(BillingEngine.endsPurchase(StoreKitError.networkError(URLError(.notConnectedToInternet))))
        XCTAssertFalse(BillingEngine.endsPurchase(StoreKitError.systemError(URLError(.unknown))))
        XCTAssertFalse(BillingEngine.endsPurchase(StoreKitError.unknown))
        XCTAssertFalse(BillingEngine.endsPurchase(URLError(.timedOut)))
    }

    func testIntentSurvivesUnrelatedDeliveriesAndOnlyLeavesWhenRecorded() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_a"))
        let engine = env.engine(transport: transport, storage: storage)
        let intent = try await engine.beginPurchase(productId: "pro_monthly")
        // A different product, and a renewal, are delivered and recorded: the intent stays.
        _ = await engine.process(BillingFixtures.update(original(), counter: FinishCounter()))
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(productId: "pro_monthly"), counter: FinishCounter()))
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [intent])

        let monthly = StoreTransaction(
            id: "3000000000000002", originalId: "3000000000000002", productId: "pro_monthly", kind: .autoRenewable,
            purchaseDate: BillingFixtures.now, expirationDate: nil, revocationDate: nil, isUpgraded: false,
            periodType: .normal, signedTransaction: "jws.m", appAccountToken: nil
        )
        _ = await engine.process(BillingFixtures.update(monthly, counter: FinishCounter()))
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [], "recorded: removed")
    }
}
