import XCTest
@testable import AppRefer

@available(iOS 15.0, macOS 12.0, *)
final class BillingEngineTests: XCTestCase {
    private var env: BillingTestEnvironment!

    override func setUp() {
        super.setUp()
        env = BillingTestEnvironment()
    }

    override func tearDown() {
        env.cleanUp()
        super.tearDown()
    }

    // MARK: - Outage safety

    func testServerDownUnlocksFromStoreKit() async {
        let storeKit = FakeStoreKit(entitlements: [BillingFixtures.transaction()])
        let engine = env.engine(
            transport: MockBillingTransport.unreachable(), storeKit: storeKit,
            options: .init(productEntitlements: ["pro_yearly": ["premium"]])
        )

        let info = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(info.source, .localFallback)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertTrue(BillingStorage.isAnonymous(info.appUserId))
    }

    func testServerErrorStatusAlsoFallsBack() async {
        let storeKit = FakeStoreKit(entitlements: [BillingFixtures.transaction()])
        let transport = MockBillingTransport { _ in (Data(#"{"error":"Billing not enabled for this app"}"#.utf8), 404) }
        let engine = env.engine(transport: transport, storeKit: storeKit)

        let info = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
    }

    func testServerDownKeepsCachedEntitlementsForSameUserOnly() async {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_1"
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1", entitlement: "web_pro"))
        let engine = env.engine(transport: transport, storage: storage)

        let online = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(online.source, .server)

        transport.setHandler { _ in throw AppReferBillingError.network("offline") }
        let offline = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(offline.source, .localFallback)
        XCTAssertEqual(offline.entitlements["web_pro"]?.isActive, true)

        _ = try? await engine.logIn("user_2")
        let otherUser = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertNil(otherUser.entitlements["web_pro"], "user_1's cache must not unlock user_2")
    }

    func testCachedOrFetchedUsesFreshCacheWithoutNetwork() async {
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, appUserId: "user_1")

        _ = await engine.customerInfo(policy: .fetchCurrent)
        let count = transport.requests.count
        let cached = await engine.customerInfo(policy: .cachedOrFetched)
        XCTAssertEqual(transport.requests.count, count)
        XCTAssertEqual(cached.source, .cache)
        XCTAssertEqual(cached.entitlements["premium"]?.isActive, true)
    }

    func testFirstFetchRegistersCustomerThenUsesGet() async throws {
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, appUserId: "user_1")

        _ = await engine.customerInfo(policy: .fetchCurrent)
        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "GET"])
        let body = try XCTUnwrap(transport.requests.first?.jsonBody)
        XCTAssertEqual(body["appreferId"] as? String, "device-abc", "attribution device id is sent automatically")
        let token = await engine.accountToken()
        XCTAssertEqual(token, UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    }

    func testAttributesAreSentWithNextCall() async throws {
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, appUserId: "user_1")
        _ = await engine.customerInfo(policy: .fetchCurrent)

        await engine.setAttributes(["$email": "a@example.com"])
        _ = await engine.customerInfo(policy: .fetchCurrent)
        let last = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.jsonBody?["attributes"] as? [String: String], ["$email": "a@example.com"])

        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(transport.requests.last?.httpMethod, "GET", "attributes cleared after sending")
    }

    // MARK: - Transactions

    func testAcceptedTransactionIsFinishedAndNotQueued() async throws {
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let queue = env.queue()
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue)
        let counter = FinishCounter()

        let info = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: counter))
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(info.source, .server)
        let body = try XCTUnwrap(transport.requests.last?.jsonBody)
        XCTAssertEqual(body["signedTransaction"] as? String, "jws.2000000000000001.sig")
        XCTAssertEqual(body["appUserId"] as? String, "user_1")
    }

    func testUnreachableServerQueuesFinishesAndStillUnlocks() async {
        let transaction = BillingFixtures.transaction()
        let storeKit = FakeStoreKit(entitlements: [transaction])
        let queue = env.queue()
        let engine = env.engine(transport: MockBillingTransport.unreachable(), storeKit: storeKit, appUserId: "user_1", queue: queue)
        let counter = FinishCounter()

        let info = await engine.process(BillingFixtures.update(transaction, counter: counter))
        XCTAssertEqual(counter.count, 1, "never leave a transaction unfinished")
        XCTAssertEqual(queue.entries.map(\.transactionId), [transaction.id])
        XCTAssertEqual(env.queue().entries.first?.signedTransaction, transaction.signedTransaction, "queue is on disk")
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(info.source, .localFallback)
    }

    func testRejectedTransactionIsFinishedNotQueued() async {
        let transaction = BillingFixtures.transaction()
        let transport = MockBillingTransport { _ in (Data(#"{"error":"Invalid transaction (bundle_mismatch)"}"#.utf8), 400) }
        let queue = env.queue()
        let engine = env.engine(transport: transport, storeKit: FakeStoreKit(entitlements: [transaction]), queue: queue)
        let counter = FinishCounter()

        let info = await engine.process(BillingFixtures.update(transaction, counter: counter))
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true, "StoreKit-verified purchase still unlocks")
    }

    func testUnverifiedTransactionIsFinishedWithoutCallingServer() async {
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "u"))
        let engine = env.engine(transport: transport)
        let counter = FinishCounter()

        let info = await engine.process(BillingFixtures.update(nil, id: "bad", counter: counter))
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(info.hasActiveEntitlement)
    }

    func testQueueDrainsWhenServerComesBack() async {
        let transaction = BillingFixtures.transaction()
        let transport = MockBillingTransport.unreachable()
        let queue = env.queue()
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: [transaction]),
            appUserId: "user_1", queue: queue
        )
        _ = await engine.process(BillingFixtures.update(transaction, counter: FinishCounter()))
        XCTAssertFalse(queue.isEmpty)

        transport.setHandler { _ in (Data(BillingFixtures.customerJSON(appUserId: "user_1").utf8), 200) }
        let info = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(env.queue().isEmpty)
        XCTAssertEqual(info.source, .server)
        let purchasePosts = transport.requests.filter { $0.url?.path == "/api/billing/v1/purchases" }
        XCTAssertEqual(purchasePosts.last?.jsonBody?["signedTransaction"] as? String, transaction.signedTransaction)
    }

    func testServerAnswerIsMergedWithDeviceWhilePurchaseStillQueued() async {
        // Server reachable for reads but the purchase was queued earlier (e.g. 409 config error).
        let transaction = BillingFixtures.transaction()
        let queue = env.queue()
        queue.add(PendingPurchase(
            transactionId: transaction.id, productId: transaction.productId, appUserId: "user_1",
            appreferId: nil, signedTransaction: transaction.signedTransaction, enqueuedAt: BillingFixtures.now, attempts: 1
        ))
        let transport = MockBillingTransport { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"Apple billing is not configured"}"#.utf8), 409) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_1").utf8), 200)
        }
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: [transaction]),
            appUserId: "user_1", queue: queue
        )

        let info = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertFalse(queue.isEmpty)
    }

    func testRestoreSyncsAndPostsEveryEntitlement() async {
        let storeKit = FakeStoreKit(entitlements: [
            BillingFixtures.transaction(id: "1"),
            BillingFixtures.transaction(id: "2", productId: "pro_lifetime", kind: .nonConsumable, expires: nil),
        ])
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, storeKit: storeKit, appUserId: "user_1")

        let info = try? await engine.restore()
        XCTAssertEqual(storeKit.syncCalls, 1)
        XCTAssertEqual(
            transport.requests.filter { $0.url?.path == "/api/billing/v1/purchases" }.compactMap { $0.jsonBody?["signedTransaction"] as? String },
            ["jws.1.sig", "jws.2.sig"]
        )
        XCTAssertEqual(info?.source, .server)
    }

    // MARK: - Identity

    func testLogInFromAnonymousCallsIdentify() async throws {
        let storage = env.storage()
        let anon = storage.anonymousId()
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, storage: storage)

        let info = try await engine.logIn("user_1")
        XCTAssertEqual(info.appUserId, "user_1")
        let identify = try XCTUnwrap(transport.requests.first { $0.url?.path == "/api/billing/v1/identify" })
        XCTAssertEqual(identify.jsonBody?["anonymousId"] as? String, anon)
        XCTAssertEqual(identify.jsonBody?["appUserId"] as? String, "user_1")
        XCTAssertNil(storage.pendingIdentify)
        let isAnonymous = await engine.isAnonymous
        XCTAssertFalse(isAnonymous)
    }

    func testLogInWhileOfflineRetriesIdentifyLater() async throws {
        let storage = env.storage()
        _ = storage.anonymousId()
        let transport = MockBillingTransport.unreachable()
        let engine = env.engine(transport: transport, storage: storage)

        _ = try await engine.logIn("user_1")
        XCTAssertEqual(storage.pendingIdentify?.appUserId, "user_1")

        transport.setHandler { _ in (Data(BillingFixtures.customerJSON(appUserId: "user_1").utf8), 200) }
        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertNil(storage.pendingIdentify)
    }

    func testLogInRejectsInvalidIds() async {
        let engine = env.engine(transport: MockBillingTransport.unreachable())
        for bad in ["", "has space", "$ARAnon:6F9619FF-8B86-D011-B42D-00C04FC964FF"] {
            do {
                _ = try await engine.logIn(bad)
                XCTFail("accepted \(bad)")
            } catch {
                XCTAssertEqual(error as? AppReferBillingError, .invalidAppUserId)
            }
        }
    }

    func testLogOutMintsNewAnonymousId() async throws {
        let storage = env.storage()
        let firstAnon = storage.anonymousId()
        let engine = env.engine(transport: MockBillingTransport.unreachable(), storage: storage)
        _ = try await engine.logIn("user_1")

        let info = await engine.logOut()
        XCTAssertTrue(BillingStorage.isAnonymous(info.appUserId))
        XCTAssertNotEqual(info.appUserId, firstAnon)
        XCTAssertNil(storage.loggedInAppUserId)
    }

    func testConfigureWithAppUserIdAfterAnonymousUseQueuesIdentify() {
        let storage = env.storage()
        _ = storage.anonymousId()
        _ = env.engine(transport: MockBillingTransport.unreachable(), appUserId: "user_1", storage: storage)
        XCTAssertEqual(storage.loggedInAppUserId, "user_1")
        XCTAssertEqual(storage.pendingIdentify?.appUserId, "user_1")
    }

    func testConfigureWithAppUserIdOnFreshInstallSkipsIdentify() {
        let storage = env.storage()
        _ = env.engine(transport: MockBillingTransport.unreachable(), appUserId: "user_1", storage: storage)
        XCTAssertNil(storage.pendingIdentify)
    }
}
