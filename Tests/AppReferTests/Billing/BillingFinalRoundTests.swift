import XCTest
@testable import AppRefer

/// Final review round (Astra verification, Oct 2026): pruning never drops an unsaved
/// held transaction, another owner's upload never unlocks the signed-in user, a network
/// failure on upload still asks the customer endpoint first, attribution never uses an
/// unsaved device id, and a later host's network error keeps an earlier Retry-After.
final class BillingFinalRoundTests: XCTestCase {
    private var env: BillingTestEnvironment!
    private let purchasesPath = "/api/billing/v1/purchases"
    private let mapping = BillingEngine.Options(productEntitlements: ["pro_yearly": ["gold"], "pro_monthly": ["premium"]])

    override func setUp() {
        super.setUp()
        env = BillingTestEnvironment()
    }

    override func tearDown() {
        env.cleanUp()
        super.tearDown()
    }

    // MARK: - 1. Pruning keeps unsaved entries and their held transactions

    func testPruneNeverFinishesAHeldTransactionWithoutADurableCopy() async {
        let store = FlakyPendingPurchaseStore()
        store.failWrites = true
        let queue = PendingPurchaseQueue(store: store)
        let clock = TestClock()
        let engine = env.engine(
            transport: MockBillingTransport.unreachable(), appUserId: "user_1", queue: queue, now: { clock.now }
        )
        let counter = FinishCounter()
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: counter))
        XCTAssertEqual(counter.count, 0)

        clock.advance(PendingPurchaseQueue.maxAge + 60)
        await engine.drainQueue()
        XCTAssertEqual(counter.count, 0, "too old, but unsaved: StoreKit must keep it")
        XCTAssertEqual(queue.entries.map(\.transactionId), ["2000000000000001"], "kept in memory")

        store.failWrites = false
        await engine.drainQueue()
        XCTAssertEqual(counter.count, 1, "finished once the retry copy saved")
    }

    func testQueuePruneSkipsProvisionalEntries() {
        let store = FlakyPendingPurchaseStore()
        store.failWrites = true
        let queue = PendingPurchaseQueue(store: store)
        var stale = PendingPurchase(
            transactionId: "t1", productId: "pro_yearly", appUserId: "user_1", appreferId: nil,
            signedTransaction: "jws", enqueuedAt: BillingFixtures.now, attempts: PendingPurchaseQueue.maxAttempts
        )
        queue.add(stale)
        XCTAssertTrue(queue.prune(now: BillingFixtures.now, archive: { _ in true }).isEmpty)

        store.failWrites = false
        stale.attempts += 1
        XCTAssertTrue(queue.add(stale))
        XCTAssertEqual(queue.prune(now: BillingFixtures.now, archive: { _ in true }).map(\.transactionId), ["t1"], "pruned once durable")
    }

    // MARK: - 2. Another owner's successful upload keeps the current user filtered

    private func otherOwnerSetup(customerStatus: Int) -> (BillingEngine, StoreTransaction) {
        let storage = env.storage()
        storage.setAccountToken(BillingFixtures.otherAccountToken.uuidString, for: "user_a")
        storage.loggedInAppUserId = "user_b"
        let renewal = BillingFixtures.transaction(id: "2000000000000009", productId: "pro_yearly",
                                                  appAccountToken: BillingFixtures.otherAccountToken)
        let transport = MockBillingTransport { request in
            if request.url?.path == "/api/billing/v1/purchases" {
                return (Data(BillingFixtures.customerJSON(appUserId: "user_a", entitlement: "gold").utf8), 200)
            }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_b").utf8), customerStatus)
        }
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: [renewal]), options: mapping, storage: storage
        )
        return (engine, renewal)
    }

    func testOtherOwnersUploadAnswersWithCurrentUsersServerAnswer() async {
        let (engine, renewal) = otherOwnerSetup(customerStatus: 200)
        let info = await engine.process(BillingFixtures.update(renewal, counter: FinishCounter()))
        XCTAssertEqual(info.appUserId, "user_b")
        XCTAssertEqual(info.source, .server)
        XCTAssertNil(info.entitlements["gold"], "user_a's renewal must not unlock user_b")
    }

    func testOtherOwnersUploadWithFailedCustomerFetchStaysOwnershipFiltered() async {
        let (engine, renewal) = otherOwnerSetup(customerStatus: 500)
        let info = await engine.process(BillingFixtures.update(renewal, counter: FinishCounter()))
        XCTAssertEqual(info.appUserId, "user_b")
        XCTAssertNil(info.entitlements["gold"], "AppRefer just answered: no unrestricted fallback")
    }

    // MARK: - 3. Network failure on upload still asks the customer endpoint first

    func testNetworkFailureOnUploadUsesFilteredCustomerAnswerWhenFetchSucceeds() async {
        let othersPurchase = BillingFixtures.transaction(id: "2000000000000009", productId: "pro_yearly",
                                                         appAccountToken: BillingFixtures.otherAccountToken)
        let mine = BillingFixtures.transaction(id: "2000000000000002", productId: "pro_monthly",
                                               appAccountToken: BillingFixtures.accountToken)
        let transport = MockBillingTransport { request in
            if request.url?.path == "/api/billing/v1/purchases" { throw AppReferBillingError.network("timed out") }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_b").utf8), 200)
        }
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: [othersPurchase, mine]),
            options: mapping, appUserId: "user_b"
        )
        let info = await engine.process(BillingFixtures.update(mine, counter: FinishCounter()))
        XCTAssertEqual(info.source, .server)
        XCTAssertNil(info.entitlements["gold"], "another user's purchase stays locked")
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true, "the buyer keeps theirs")
        XCTAssertFalse(transport.requests(to: "/api/billing/v1/customers").isEmpty, "one customer fetch was tried")
    }

    // MARK: - 4. Attribution never uses an unsaved device id

    func testAttributionDeviceIdIsNilOnKeychainFailureAndMatchIsRetriedLater() async {
        let suite = "com.apprefer.attribution.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = ScriptedDeviceIdKeychain()
        let storage = AppReferStorage(defaults: defaults, keychain: keychain)
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test_123", userId: nil, debug: false, logLevel: 0), storage: storage)

        keychain.readResult = .failed(errSecInternalError)
        let unreadable = await sdk._getDeviceId()
        XCTAssertNil(unreadable)

        keychain.readResult = .notFound
        keychain.addStatus = errSecInternalError
        let unsaved = await sdk._getDeviceId()
        XCTAssertNil(unsaved, "never a random id that wasn't saved")

        let attribution = await sdk._configure()
        XCTAssertNil(attribution)
        XCTAssertFalse(storage.isMatchRequestAttempted(), "match deferred to a launch with a saved id")
    }

    // MARK: - 5. A later host's network error keeps an earlier Retry-After

    func testLaterHostNetworkErrorKeepsEarlierRetryAfter() async {
        let transport = MockBillingTransport { request in
            if request.url?.host == "trk.example.com" { return (Data(#"{"error":"busy"}"#.utf8), 503) }
            throw AppReferBillingError.network("offline")
        }
        transport.retryAfter = "120"
        let api = BillingAPIClient(
            baseURLs: ["https://trk.example.com", "https://main.example.com"],
            apiKey: { "pk_test_123" }, transport: transport, keyWaitAttempts: 0
        )
        do {
            _ = try await api.send(.getCustomer(appUserId: "user_1"))
            XCTFail("expected an error")
        } catch let error as AppReferBillingError {
            XCTAssertEqual(error.retryAfter, 120)
            XCTAssertEqual(error, .server(status: 503, message: "busy", retryAfter: 120))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testLater5xxWithoutRetryAfterKeepsTheEarlierWait() {
        let merged = BillingAPIClient.keepingServerAnswer(
            .server(status: 503, message: nil, retryAfter: 120), over: .server(status: 502, message: nil, retryAfter: nil)
        )
        XCTAssertEqual(merged.retryAfter, 120)
        XCTAssertEqual(
            BillingAPIClient.keepingServerAnswer(.network("a"), over: .network("b")), .network("b")
        )
    }
}
