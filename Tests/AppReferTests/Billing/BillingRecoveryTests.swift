import XCTest
@testable import AppRefer

/// Release blockers (Astra final check, Oct 2026): (1) a purchase AppRefer refuses for
/// good, StoreKit can't verify, or the retry queue gives up on is saved to a rejected list
/// before it is finished (consumables never finished) and Restore sends it again;
/// (2) who opened the purchase sheet is saved first and owns later deliveries.
final class BillingRecoveryTests: XCTestCase {
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

    private var rejectedURL: URL { env.directory.appendingPathComponent("rejected_purchases.json") }
    private var intentsURL: URL { env.directory.appendingPathComponent("purchase_intents.json") }

    private func rejecting(_ status: Int = 400) -> MockBillingTransport {
        MockBillingTransport { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"Invalid transaction"}"#.utf8), status) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_1").utf8), 200)
        }
    }

    /// An original purchase (StoreKit: `originalID == id`).
    private func original(
        id: String = "3000000000000001", productId: String = "pro_yearly",
        kind: StoreTransaction.Kind = .autoRenewable, token: UUID? = nil
    ) -> StoreTransaction {
        StoreTransaction(
            id: id, originalId: id, productId: productId, kind: kind,
            purchaseDate: BillingFixtures.now, expirationDate: BillingFixtures.now.addingTimeInterval(86_400),
            revocationDate: nil, isUpgraded: false, periodType: .normal,
            signedTransaction: "jws.\(id).sig", appAccountToken: token
        )
    }

    // MARK: - 1. Rejected-purchase archive

    func testPermanentRejectionIsArchivedOnDiskThenFinished() async throws {
        let counter = FinishCounter()
        let engine = env.engine(transport: rejecting(422), appUserId: "user_1")
        let transaction = BillingFixtures.transaction(appAccountToken: BillingFixtures.accountToken)
        _ = await engine.process(BillingFixtures.update(transaction, counter: counter))

        XCTAssertEqual(counter.count, 1)
        let saved = try XCTUnwrap(RejectedPurchaseLog(fileURL: rejectedURL).entries.first, "on disk")
        XCTAssertEqual(saved.transactionId, transaction.id)
        XCTAssertEqual(saved.signedTransaction, transaction.signedTransaction)
        XCTAssertEqual(saved.appUserId, "user_1")
        XCTAssertEqual(saved.productId, "pro_yearly")
        XCTAssertEqual(saved.accountToken, BillingFixtures.accountToken)
        XCTAssertEqual(saved.kind, "autoRenewable")
        XCTAssertTrue(saved.verifiedByStoreKit)
        let publicList = await engine.rejectedPurchases()
        XCTAssertEqual(publicList, [saved])
    }

    func testRejectedConsumableIsArchivedButNeverFinished() async {
        let counter = FinishCounter()
        let engine = env.engine(transport: rejecting(400), appUserId: "user_1")
        let coins = BillingFixtures.transaction(productId: "coins_100", kind: .consumable, expires: nil)
        _ = await engine.process(BillingFixtures.update(coins, counter: counter))
        XCTAssertEqual(counter.count, 0, "StoreKit keeps it")
        XCTAssertEqual(RejectedPurchaseLog(fileURL: rejectedURL).entries.map(\.kind), ["consumable"])
    }

    func testRejectionWhoseArchiveCantBeSavedStaysUnfinished() async {
        let store = FlakyPendingPurchaseStore()
        store.failWrites = true
        let log = RejectedPurchaseLog(store: store)
        let engine = BillingEngineFactory.make(env, transport: rejecting(), rejected: log)
        let counter = FinishCounter()
        let transaction = BillingFixtures.transaction()
        _ = await engine.process(BillingFixtures.update(transaction, counter: counter))
        XCTAssertEqual(counter.count, 0, "no durable copy: StoreKit must deliver it again")

        store.failWrites = false
        _ = await engine.process(BillingFixtures.update(transaction, counter: counter)) // redelivery
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(RejectedPurchaseLog(store: store).entries.map(\.transactionId), [transaction.id])
    }

    func testUnverifiedTransactionIsArchivedWithItsJWS() async {
        let engine = env.engine(transport: MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_1")), appUserId: "user_1")
        let counter = FinishCounter()
        let claimed = BillingFixtures.transaction(id: "bad1")
        let update = StoreKitUpdate(verified: nil, transactionId: "bad1", finish: { counter.increment() }, unverifiedPayload: claimed)
        _ = await engine.process(update)
        XCTAssertEqual(counter.count, 1)
        let saved = RejectedPurchaseLog(fileURL: rejectedURL).entries
        XCTAssertEqual(saved.map(\.signedTransaction), ["jws.bad1.sig"])
        XCTAssertEqual(saved.first?.verifiedByStoreKit, false)

        let consumableCounter = FinishCounter()
        let coins = BillingFixtures.transaction(id: "bad2", productId: "coins_100", kind: .consumable, expires: nil)
        _ = await engine.process(StoreKitUpdate(verified: nil, transactionId: "bad2", finish: { consumableCounter.increment() }, unverifiedPayload: coins))
        XCTAssertEqual(consumableCounter.count, 0, "unverified consumable is never finished")
        XCTAssertEqual(RejectedPurchaseLog(fileURL: rejectedURL).entries.count, 2)
    }

    func testUnverifiedTransactionStaysUnfinishedWhenArchiveFails() async {
        let store = FlakyPendingPurchaseStore()
        store.failWrites = true
        let engine = BillingEngineFactory.make(env, transport: MockBillingTransport.unreachable(), rejected: RejectedPurchaseLog(store: store))
        let counter = FinishCounter()
        let update = StoreKitUpdate(verified: nil, transactionId: "bad", finish: { counter.increment() },
                                    unverifiedPayload: BillingFixtures.transaction(id: "bad"))
        _ = await engine.process(update)
        XCTAssertEqual(counter.count, 0)
    }

    func testQueuedPurchaseRejectedLaterMovesToArchiveBeforeLeavingQueue() async {
        let transport = MockBillingTransport.unreachable()
        let queue = env.queue()
        let archiveStore = FlakyPendingPurchaseStore()
        let engine = BillingEngineFactory.make(env, transport: transport, queue: queue, rejected: RejectedPurchaseLog(store: archiveStore))
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()))
        XCTAssertEqual(queue.entries.count, 1)

        transport.setHandler { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"bad"}"#.utf8), 413) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_1").utf8), 200)
        }
        archiveStore.failWrites = true
        await engine.drainQueue()
        XCTAssertEqual(queue.entries.count, 1, "kept queued until the archive copy is saved")

        archiveStore.failWrites = false
        await engine.drainQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(RejectedPurchaseLog(store: archiveStore).entries.map(\.transactionId), ["2000000000000001"])
        XCTAssertEqual(RejectedPurchaseLog(store: archiveStore).entries.first?.signedTransaction, "jws.2000000000000001.sig")
    }

    func testRejectedHeldConsumableFromQueueIsNotFinished() async {
        let queueStore = FlakyPendingPurchaseStore()
        queueStore.failWrites = true
        let queue = PendingPurchaseQueue(store: queueStore)
        let transport = MockBillingTransport.unreachable()
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue)
        let counter = FinishCounter()
        let coins = BillingFixtures.transaction(productId: "coins_100", kind: .consumable, expires: nil)
        _ = await engine.process(BillingFixtures.update(coins, counter: counter))
        XCTAssertEqual(counter.count, 0, "held: retry copy not saved")

        transport.setHandler { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"bad"}"#.utf8), 400) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_1").utf8), 200)
        }
        await engine.drainQueue()
        XCTAssertEqual(counter.count, 0, "rejected consumable is never finished")
        XCTAssertEqual(RejectedPurchaseLog(fileURL: rejectedURL).entries.map(\.kind), ["consumable"])
        XCTAssertTrue(queue.isEmpty)
    }

    func testGivenUpQueueEntryIsArchivedBeforeItIsPruned() async {
        let queue = env.queue()
        queue.add(PendingPurchase(
            transactionId: "t1", productId: "pro_yearly", appUserId: "user_1", appreferId: nil,
            signedTransaction: "jws.t1", enqueuedAt: BillingFixtures.now, attempts: PendingPurchaseQueue.maxAttempts
        ))
        let archiveStore = FlakyPendingPurchaseStore()
        archiveStore.failWrites = true
        let engine = BillingEngineFactory.make(env, transport: MockBillingTransport.unreachable(), queue: queue,
                                               rejected: RejectedPurchaseLog(store: archiveStore))
        await engine.drainQueue()
        XCTAssertEqual(queue.entries.map(\.transactionId), ["t1"], "not pruned without an archive copy")

        archiveStore.failWrites = false
        await engine.drainQueue()
        XCTAssertTrue(queue.isEmpty)
        let saved = RejectedPurchaseLog(store: archiveStore).entries
        XCTAssertEqual(saved.map(\.signedTransaction), ["jws.t1"])
        XCTAssertEqual(saved.first?.reason.hasPrefix("not recorded after"), true)
    }

    func testArchiveTracksSavedContentsNotJustTheKey() {
        let store = FlakyPendingPurchaseStore()
        let log = RejectedPurchaseLog(store: store)
        let first = AppReferRejectedPurchase(
            transactionId: "t1", productId: "p", appUserId: "u", appreferId: nil, signedTransaction: "jws",
            accountToken: nil, kind: "consumable", verifiedByStoreKit: true, reason: "a", rejectedAt: BillingFixtures.now
        )
        XCTAssertTrue(log.add(first))
        store.failWrites = true
        let second = AppReferRejectedPurchase(
            transactionId: "t1", productId: "p", appUserId: "other", appreferId: nil, signedTransaction: "jws",
            accountToken: nil, kind: "consumable", verifiedByStoreKit: true, reason: "b", rejectedAt: BillingFixtures.now
        )
        XCTAssertFalse(log.add(second), "only the older contents are on disk")
    }

    func testUnreadableArchiveIsNeverOverwritten() {
        let store = FlakyPendingPurchaseStore()
        let entry = { (id: String) in AppReferRejectedPurchase(
            transactionId: id, productId: "p", appUserId: nil, appreferId: nil, signedTransaction: "jws.\(id)",
            accountToken: nil, kind: nil, verifiedByStoreKit: true, reason: "r", rejectedAt: BillingFixtures.now
        ) }
        XCTAssertTrue(RejectedPurchaseLog(store: store).add(entry("old")))
        store.failReads = true
        let log = RejectedPurchaseLog(store: store)
        XCTAssertFalse(log.add(entry("new")))
        XCTAssertEqual(RejectedPurchaseLogTestReader.ids(store), ["old"], "file untouched")
        store.failReads = false
        XCTAssertTrue(log.add(entry("new")))
        XCTAssertEqual(Set(RejectedPurchaseLogTestReader.ids(store)), ["old", "new"])
    }

    func testRestoreResendsArchivedPurchasesAndFinishesRecordedConsumables() async throws {
        let storeKit = FakeStoreKit()
        let counter = FinishCounter()
        let coins = BillingFixtures.transaction(id: "c1", productId: "coins_100", kind: .consumable, expires: nil)
        storeKit.unfinished = [BillingFixtures.update(coins, counter: counter)]
        let transport = rejecting(400)
        let engine = env.engine(transport: transport, storeKit: storeKit, appUserId: "user_1")
        _ = await engine.process(BillingFixtures.update(coins, counter: counter))
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(RejectedPurchaseLog(fileURL: rejectedURL).entries.count, 1)

        transport.setHandler { _ in (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_1").utf8), 200) }
        _ = try await engine.restore()
        let body = try XCTUnwrap(transport.requests(to: purchasesPath).last?.jsonBody)
        XCTAssertEqual(body["signedTransaction"] as? String, "jws.c1.sig")
        XCTAssertEqual(body["restore"] as? Bool, true)
        XCTAssertEqual(body["appUserId"] as? String, "user_1")
        XCTAssertTrue(RejectedPurchaseLog(fileURL: rejectedURL).entries.isEmpty, "recorded: dropped from the list")
        XCTAssertEqual(counter.count, 1, "consumable finished once AppRefer recorded it")
    }

    func testRestoreKeepsArchivedPurchaseWhenStillRefused() async throws {
        let engine = env.engine(transport: rejecting(400), appUserId: "user_1")
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()))
        _ = try await engine.restore()
        XCTAssertEqual(RejectedPurchaseLog(fileURL: rejectedURL).entries.count, 1)
    }

    // MARK: - 2. Persisted purchase intent

    func testBeginPurchaseSavesIntentOnDisk() async throws {
        let storage = env.storage()
        storage.setAccountToken(BillingFixtures.accountToken.uuidString, for: "user_a")
        storage.loggedInAppUserId = "user_a"
        let engine = env.engine(transport: MockBillingTransport.unreachable(), storage: storage)
        let intent = try await engine.beginPurchase(productId: "pro_yearly")
        XCTAssertEqual(intent.appUserId, "user_a")
        XCTAssertEqual(intent.accountToken, BillingFixtures.accountToken)
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [intent])

        await engine.endPurchase(intent) // cancelled
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [])
    }

    func testBeginPurchaseThrowsWhenIntentCantBeSaved() async {
        let store = FlakyPendingPurchaseStore()
        store.failWrites = true
        let engine = BillingEngineFactory.make(env, transport: MockBillingTransport.unreachable(), intents: PurchaseIntentStore(store: store, lostMarker: FlakyPendingPurchaseStore()))
        do {
            _ = try await engine.beginPurchase(productId: "pro_yearly")
            XCTFail("must not open the sheet")
        } catch {
            XCTAssertEqual(error as? AppReferBillingError, .purchaseIntentNotSaved)
        }
        store.failWrites = false
        XCTAssertEqual(PurchaseIntentStore(store: store, lostMarker: FlakyPendingPurchaseStore()).intents, [])
    }

    func testUntaggedDeliveryAfterRestartAndUserSwitchGoesToSavedIntent() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let first = env.engine(transport: MockBillingTransport.unreachable(), storage: storage)
        let intent = try await first.beginPurchase(productId: "pro_yearly")
        XCTAssertNil(intent.accountToken, "AppRefer unreachable: purchase goes ahead untagged")

        // Ask to Buy approved after a restart and a switch to user_b.
        storage.loggedInAppUserId = "user_b"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_a"))
        let restarted = env.engine(transport: transport, storage: storage)
        let counter = FinishCounter()
        _ = await restarted.process(BillingFixtures.update(original(), counter: counter))
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["appUserId"] as? String, "user_a")
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [], "resolved intent removed")
    }

    func testTaggedDeliveryWithUnknownTokenUsesIntentCarryingThatToken() async throws {
        let storage = env.storage()
        storage.setAccountToken(BillingFixtures.otherAccountToken.uuidString, for: "user_a")
        storage.loggedInAppUserId = "user_a"
        let first = env.engine(transport: MockBillingTransport.unreachable(), storage: storage)
        _ = try await first.beginPurchase(productId: "pro_yearly")

        env.defaults.removeObject(forKey: "apprefer_billing_account_tokens") // token map lost
        storage.loggedInAppUserId = "user_b"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_b"))
        let restarted = env.engine(transport: transport, storage: storage)
        _ = await restarted.process(BillingFixtures.update(original(token: BillingFixtures.otherAccountToken), counter: FinishCounter()))
        XCTAssertEqual(transport.requests(to: purchasesPath).first?.jsonBody?["appUserId"] as? String, "user_a")
    }

    func testUnreadableIntentsDeferUntaggedDeliveryInsteadOfGivingItToCurrentUser() async throws {
        let store = FlakyPendingPurchaseStore()
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let first = BillingEngineFactory.make(env, transport: MockBillingTransport.unreachable(), storage: storage,
                                              intents: PurchaseIntentStore(store: store, lostMarker: FlakyPendingPurchaseStore()))
        _ = try await first.beginPurchase(productId: "pro_yearly")

        storage.loggedInAppUserId = "user_b"
        store.failReads = true
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_a"))
        let restarted = BillingEngineFactory.make(env, transport: transport, storage: storage, intents: PurchaseIntentStore(store: store, lostMarker: FlakyPendingPurchaseStore()))
        let counter = FinishCounter()
        _ = await restarted.process(BillingFixtures.update(original(), counter: counter))
        XCTAssertEqual(counter.count, 0, "left unfinished")
        XCTAssertTrue(transport.requests(to: purchasesPath).isEmpty, "never sent for the current user")

        store.failReads = false
        await restarted.drainQueue()
        XCTAssertEqual(transport.requests(to: purchasesPath).map { $0.jsonBody?["appUserId"] as? String }, ["user_a"])
        XCTAssertEqual(counter.count, 1)
    }

    func testRenewalsNeverMatchIntentsAndAreNotDeferredByThem() async throws {
        let store = FlakyPendingPurchaseStore()
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let first = BillingEngineFactory.make(env, transport: MockBillingTransport.unreachable(), storage: storage,
                                              intents: PurchaseIntentStore(store: store, lostMarker: FlakyPendingPurchaseStore()))
        _ = try await first.beginPurchase(productId: "pro_yearly")
        storage.loggedInAppUserId = "user_b"
        store.failReads = true
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_b"))
        let engine = BillingEngineFactory.make(env, transport: transport, storage: storage, intents: PurchaseIntentStore(store: store, lostMarker: FlakyPendingPurchaseStore()))
        // Fixture transactions are renewals (originalId != id).
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()))
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["appUserId"] as? String, "user_b")
    }

    func testPendingIntentIsNotExpiredByAge() async throws {
        let clock = TestClock()
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let first = env.engine(transport: MockBillingTransport.unreachable(), storage: storage, now: { clock.now })
        _ = try await first.beginPurchase(productId: "pro_yearly")

        clock.advance(60 * 24 * 3600)
        storage.loggedInAppUserId = "user_b"
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_a"))
        let later = env.engine(transport: transport, storage: storage, now: { clock.now })
        let late = StoreTransaction(
            id: "3000000000000009", originalId: "3000000000000009", productId: "pro_yearly", kind: .autoRenewable,
            purchaseDate: clock.now, expirationDate: clock.now.addingTimeInterval(86_400), revocationDate: nil,
            isUpgraded: false, periodType: .normal, signedTransaction: "jws.late", appAccountToken: nil
        )
        _ = await later.process(BillingFixtures.update(late, counter: FinishCounter()))
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["appUserId"] as? String, "user_a")
    }

    func testIntentKeptWhileDeliveryIsNotSecured() async throws {
        let queueStore = FlakyPendingPurchaseStore()
        queueStore.failWrites = true
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let engine = env.engine(transport: MockBillingTransport.unreachable(), storage: storage, queue: PendingPurchaseQueue(store: queueStore))
        let intent = try await engine.beginPurchase(productId: "pro_yearly")
        _ = await engine.process(BillingFixtures.update(original(), counter: FinishCounter()), initiator: "user_a", intent: intent)
        XCTAssertEqual(PurchaseIntentStore(fileURL: intentsURL).intents, [intent], "retry copy unsaved: intent still needed")
    }
}

private enum RejectedPurchaseLogTestReader {
    static func ids(_ store: FlakyPendingPurchaseStore) -> [String] {
        (store.data.flatMap { try? JSONDecoder().decode([AppReferRejectedPurchase].self, from: $0) } ?? []).map(\.transactionId)
    }
}

private enum BillingEngineFactory {
    static func make(
        _ env: BillingTestEnvironment,
        transport: BillingTransport,
        storage: BillingStorage? = nil,
        queue: PendingPurchaseQueue? = nil,
        rejected: RejectedPurchaseLog? = nil,
        intents: PurchaseIntentStore? = nil
    ) -> BillingEngine {
        let storage = storage ?? {
            let s = env.storage()
            s.loggedInAppUserId = "user_1"
            return s
        }()
        return BillingEngine(
            api: BillingAPIClient(
                baseURLs: ["https://trk.example.com"], apiKey: { "pk_test_123" }, transport: transport, keyWaitAttempts: 0
            ),
            storage: storage,
            queue: queue ?? env.queue(),
            rejected: rejected,
            intents: intents,
            storeKit: FakeStoreKit(),
            options: .init(),
            appUserId: nil,
            appreferId: { "device-abc" },
            logger: AppReferLogger(debug: false, logLevel: 0),
            now: { BillingFixtures.now }
        )
    }
}
