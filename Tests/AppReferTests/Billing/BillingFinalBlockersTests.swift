import StoreKit
import XCTest
@testable import AppRefer

/// Final release blockers shared by all four SDKs (Oct 2026): (1) a renewal never uses or
/// consumes an intent, including one the purchase sheet supplies; (2) intents leave only on
/// definitive store outcomes and a second purchase start keeps the first intent; (3) the
/// oldest intent is the minimum `startedAt`; (4) a partly malformed intents file keeps its
/// parseable entries, is quarantined and sets the lost marker.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
final class BillingFinalBlockersTests: XCTestCase {
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

    private func original(id: String = "3000000000000001") -> StoreTransaction {
        StoreTransaction(
            id: id, originalId: id, productId: "pro_yearly", kind: .autoRenewable,
            purchaseDate: BillingFixtures.now, expirationDate: BillingFixtures.now.addingTimeInterval(86_400),
            revocationDate: nil, isUpgraded: false, periodType: .normal, signedTransaction: "jws.\(id).sig"
        )
    }

    // MARK: 1. Renewal guard on every path

    func testRenewalReturnedByThePurchaseSheetDoesNotConsumeTheSuppliedIntent() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_a"))
        let engine = env.engine(transport: transport, storage: storage)
        let intent = try await engine.beginPurchase(productId: "pro_yearly")

        let renewal = BillingFixtures.transaction() // originalId != id
        _ = await engine.process(BillingFixtures.update(renewal, counter: FinishCounter()), initiator: "user_a", intent: intent)
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["appUserId"] as? String, "user_a", "owner from the initiator")
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [intent], "renewal recorded, intent kept")

        // The real new purchase still consumes it.
        _ = await engine.process(BillingFixtures.update(original(), counter: FinishCounter()), initiator: "user_a", intent: intent)
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [])
    }

    func testRefusedRenewalFromThePurchaseSheetKeepsTheSuppliedIntent() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_a"))
        let engine = env.engine(transport: transport, storage: storage)
        let intent = try await engine.beginPurchase(productId: "pro_yearly")
        transport.setHandler { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"bad"}"#.utf8), 400) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_a").utf8), 200)
        }
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()),
                                 initiator: "user_a", intent: intent)
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [intent], "archived renewal leaves the intent")
    }

    // MARK: 2. Definitive-only removal

    func testAmbiguousPurchaseErrorsKeepTheIntentAndDefinitiveOnesDropIt() {
        let definitive: [Error] = [
            StoreKitError.userCancelled, StoreKitError.notAvailableInStorefront, StoreKitError.notEntitled,
            Product.PurchaseError.productUnavailable, Product.PurchaseError.purchaseNotAllowed,
            Product.PurchaseError.ineligibleForOffer, Product.PurchaseError.invalidOfferIdentifier,
            Product.PurchaseError.invalidOfferPrice, Product.PurchaseError.invalidOfferSignature,
            Product.PurchaseError.missingOfferParameters, Product.PurchaseError.invalidQuantity,
        ]
        for error in definitive { XCTAssertTrue(BillingEngine.endsPurchase(error), "\(error)") }
        let ambiguous: [Error] = [
            StoreKitError.networkError(URLError(.notConnectedToInternet)), StoreKitError.systemError(URLError(.unknown)),
            StoreKitError.unknown, URLError(.timedOut), CocoaError(.fileReadUnknown),
        ]
        for error in ambiguous { XCTAssertFalse(BillingEngine.endsPurchase(error), "\(error)") }
    }

    func testSecondPurchaseStartForTheSameUserAndProductKeepsBothIntents() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let engine = env.engine(transport: MockBillingTransport.unreachable(), storage: storage)
        let first = try await engine.beginPurchase(productId: "pro_yearly")
        let second = try await engine.beginPurchase(productId: "pro_yearly")
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [first, second])
    }

    // MARK: 3. Oldest by startedAt

    func testOldestByStartedAtWinsEvenWhenStoredOutOfOrder() {
        let store = PurchaseIntentStore(fileURL: intentsURL)
        let newer = PurchaseIntent(appUserId: "user_new", productId: "pro_yearly", accountToken: nil,
                                   startedAt: BillingFixtures.now.addingTimeInterval(-60))
        let oldest = PurchaseIntent(appUserId: "user_old", productId: "pro_yearly", accountToken: nil,
                                    startedAt: BillingFixtures.now.addingTimeInterval(-3600))
        let middle = PurchaseIntent(appUserId: "user_mid", productId: "pro_yearly", accountToken: nil,
                                    startedAt: BillingFixtures.now.addingTimeInterval(-600))
        XCTAssertTrue(store.add(newer))
        XCTAssertTrue(store.add(oldest))
        XCTAssertTrue(store.add(middle))
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).match(original()), .found(oldest))
    }

    // MARK: 4. Partial corruption

    func testPartlyMalformedIntentsFileKeepsParseableEntriesQuarantinesTheOriginalAndSetsTheMarker() throws {
        let good1 = PurchaseIntent(appUserId: "user_a", productId: "pro_yearly", accountToken: nil,
                                   startedAt: BillingFixtures.now.addingTimeInterval(-600))
        let good2 = PurchaseIntent(appUserId: "user_b", productId: "pro_monthly", accountToken: BillingFixtures.accountToken,
                                   startedAt: BillingFixtures.now.addingTimeInterval(-60))
        let raw = Data("[\(try json(good1)),{\"appUserId\":42},\"junk\",\(try json(good2))]".utf8)
        let intents = FlakyPendingPurchaseStore()
        intents.data = raw
        let marker = FlakyPendingPurchaseStore()

        let store = PurchaseIntentStore(store: intents, lostMarker: marker)
        XCTAssertEqual(store.intents, [good1, good2], "parseable intents kept")
        XCTAssertEqual(intents.quarantined, raw, "raw original moved aside")
        guard case .lost = store.lostMarker.state else { return XCTFail("lost marker persisted") }
        XCTAssertNotNil(marker.data)
        // The file was rewritten with the kept intents.
        XCTAssertEqual(PurchaseIntentStore(store: intents, lostMarker: marker).intents, [good1, good2])
        XCTAssertEqual(try decodeList(like: good1, from: XCTUnwrap(intents.data)), [good1, good2])
        // Tagged deliveries still match their kept intent; untagged ones wait.
        var tagged = original()
        tagged.appAccountToken = BillingFixtures.accountToken
        XCTAssertEqual(store.match(tagged), .found(good2))
        guard case .lost = store.match(original()) else { return XCTFail("untagged purchases wait while intents are lost") }
    }

    func testWhollyUnparseableIntentsFileKeepsNothingQuarantinesAndSetsTheMarker() {
        let intents = FlakyPendingPurchaseStore()
        intents.data = Data("{\"not\":\"a list\"}".utf8)
        let marker = FlakyPendingPurchaseStore()
        let store = PurchaseIntentStore(store: intents, lostMarker: marker)
        XCTAssertEqual(store.intents, [])
        XCTAssertEqual(intents.quarantined, Data("{\"not\":\"a list\"}".utf8))
        XCTAssertNil(intents.data, "nothing to write back")
        guard case .lost = store.lostMarker.state else { return XCTFail("lost marker persisted") }
    }
}

/// StoreKit also declares `PurchaseIntent`, so ours is passed generically rather than named.
private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func decodeList<T: Decodable>(like _: T, from data: Data) throws -> [T] {
    try JSONDecoder().decode([T].self, from: data)
}
