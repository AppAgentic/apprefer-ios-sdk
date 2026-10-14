import XCTest
@testable import AppRefer

/// Queue file fake that can fail reads and writes.
final class FlakyPendingPurchaseStore: PendingPurchaseStore {
    var data: Data?
    var failWrites = false
    var failReads = false
    private(set) var quarantined: Data?

    func read() throws -> Data? {
        if failReads { throw CocoaError(.fileReadNoPermission) }
        return data
    }

    func write(_ data: Data) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        self.data = data
    }

    func quarantine() -> Bool {
        quarantined = data
        data = nil
        return true
    }

    var storedEntries: [PendingPurchase] {
        data.flatMap { try? JSONDecoder().decode([PendingPurchase].self, from: $0) } ?? []
    }
}

/// Second review round (Astra verification, Oct 2026): durable queue before finish,
/// initiator-bound purchases, ownership-filtered answers while AppRefer answers,
/// identity minting, restore ownership, Retry-After and legacy "conversion: failed".
@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
final class BillingSecondRoundTests: XCTestCase {
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

    private func entry(_ id: String = "2000000000000001", user: String = "user_1", restore: Bool? = nil) -> PendingPurchase {
        PendingPurchase(
            transactionId: id, productId: "pro_yearly", appUserId: user, appreferId: nil,
            signedTransaction: "jws.\(id).sig", enqueuedAt: BillingFixtures.now, attempts: 0, restore: restore
        )
    }

    // MARK: - Finish only after the retry copy is durable

    func testFailedQueueSaveLeavesTransactionUnfinishedUntilSaved() async {
        let store = FlakyPendingPurchaseStore()
        store.failWrites = true
        let queue = PendingPurchaseQueue(store: store)
        let transport = MockBillingTransport.unreachable()
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue)
        let counter = FinishCounter()

        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: counter))
        XCTAssertEqual(counter.count, 0, "no durable retry copy: StoreKit must keep it")
        XCTAssertFalse(queue.isDurable(transactionId: "2000000000000001"))
        XCTAssertEqual(queue.entries.count, 1, "kept provisionally in memory")

        await engine.drainQueue()
        XCTAssertEqual(counter.count, 0, "still can't save")

        store.failWrites = false
        await engine.drainQueue()
        XCTAssertEqual(counter.count, 1, "finished once saved")
        XCTAssertEqual(store.storedEntries.map(\.transactionId), ["2000000000000001"])
    }

    func testUnsavedTransactionIsFinishedOnceAppReferRecordsIt() async {
        let store = FlakyPendingPurchaseStore()
        store.failWrites = true
        let queue = PendingPurchaseQueue(store: store)
        let transport = MockBillingTransport.unreachable()
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue)
        let counter = FinishCounter()
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: counter))

        transport.setHandler { _ in (Data(BillingFixtures.customerJSON(appUserId: "user_1").utf8), 200) }
        await engine.drainQueue()
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(queue.isEmpty)
    }

    func testUnreadableQueueFileIsPreservedAndReadAgainLater() throws {
        let store = FlakyPendingPurchaseStore()
        store.data = try JSONEncoder().encode([entry("old")])
        store.failReads = true
        let queue = PendingPurchaseQueue(store: store)
        XCTAssertTrue(queue.isUnreadable)

        XCTAssertFalse(queue.add(entry("new")), "never overwrite a file we couldn't read")
        XCTAssertEqual(store.storedEntries.map(\.transactionId), ["old"])

        store.failReads = false
        XCTAssertTrue(queue.retryPersistence())
        XCTAssertFalse(queue.isUnreadable)
        XCTAssertEqual(Set(store.storedEntries.map(\.transactionId)), ["old", "new"])
        XCTAssertTrue(queue.isDurable(transactionId: "new"))
        XCTAssertTrue(queue.isDurable(transactionId: "old"))
    }

    func testCorruptQueueFileIsSetAsideNotBlocking() {
        let store = FlakyPendingPurchaseStore()
        store.data = Data("not json".utf8)
        let queue = PendingPurchaseQueue(store: store)
        XCTAssertFalse(queue.isUnreadable)
        XCTAssertEqual(store.quarantined, Data("not json".utf8))
        XCTAssertTrue(queue.add(entry()))
    }

    // MARK: - Purchases bound to the initiating identity

    func testPurchaseStaysWithInitiatorWhenAnotherUserLogsInDuringSheet() async throws {
        let storage = env.storage()
        storage.setAccountToken(BillingFixtures.otherAccountToken.uuidString, for: "user_a")
        storage.loggedInAppUserId = "user_a"
        let transport = MockBillingTransport.unreachable()
        let queue = env.queue()
        let engine = env.engine(transport: transport, storage: storage, queue: queue)

        let started = try await engine.beginPurchase(productId: "pro_yearly")
        XCTAssertEqual(started.appUserId, "user_a")
        XCTAssertEqual(started.accountToken, BillingFixtures.otherAccountToken)

        _ = try await engine.logIn("user_b") // during the purchase sheet
        let transaction = BillingFixtures.transaction(appAccountToken: started.accountToken)
        _ = await engine.process(BillingFixtures.update(transaction, counter: FinishCounter()), initiator: started.appUserId, intent: started)
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["appUserId"] as? String, "user_a")
        XCTAssertEqual(queue.entries.first?.appUserId, "user_a")

        // B's answer while AppRefer is reachable doesn't include A's purchase.
        transport.setHandler { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"later"}"#.utf8), 409) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_b").utf8), 200)
        }
        let storeKit = FakeStoreKit(entitlements: [transaction])
        let engineB = env.engine(transport: transport, storeKit: storeKit, storage: storage, queue: queue)
        let info = await engineB.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(info.appUserId, "user_b")
        XCTAssertNil(info.entitlements["premium"])
    }

    func testListenerUpdateGoesToTheOwnerOfItsAccountToken() async throws {
        let storage = env.storage()
        storage.setAccountToken(BillingFixtures.otherAccountToken.uuidString, for: "user_a")
        storage.loggedInAppUserId = "user_b"
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_a"))
        let engine = env.engine(transport: transport, storage: storage)

        let renewal = BillingFixtures.transaction(appAccountToken: BillingFixtures.otherAccountToken)
        _ = await engine.process(BillingFixtures.update(renewal, counter: FinishCounter()))
        let body = try XCTUnwrap(transport.requests(to: purchasesPath).last?.jsonBody)
        XCTAssertEqual(body["appUserId"] as? String, "user_a")
        XCTAssertNil(body["restore"])

        let untagged = BillingFixtures.transaction(id: "2000000000000002")
        _ = await engine.process(BillingFixtures.update(untagged, counter: FinishCounter()))
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["appUserId"] as? String, "user_b")
    }

    // MARK: - Unrestricted fallback only for a total outage

    private let mapping = BillingEngine.Options(productEntitlements: ["pro_yearly": ["gold"], "pro_monthly": ["premium"]])

    private func partialFailureSetup(purchaseStatus: Int) -> (BillingEngine, StoreTransaction, PendingPurchaseQueue) {
        let othersPurchase = BillingFixtures.transaction(id: "2000000000000009", productId: "pro_yearly",
                                                         appAccountToken: BillingFixtures.otherAccountToken)
        let mine = BillingFixtures.transaction(id: "2000000000000002", productId: "pro_monthly",
                                               appAccountToken: BillingFixtures.accountToken)
        let storage = env.storage()
        storage.loggedInAppUserId = "user_b"
        let transport = MockBillingTransport { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"no"}"#.utf8), purchaseStatus) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_b").utf8), 200)
        }
        let queue = env.queue()
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: [othersPurchase, mine]),
            options: mapping, storage: storage, queue: queue
        )
        return (engine, mine, queue)
    }

    func testRejectedUploadWhileAppReferAnswersDoesNotUnlockOtherUsersPurchase() async {
        for status in [400, 409, 503] {
            let (engine, mine, _) = partialFailureSetup(purchaseStatus: status)
            let info = await engine.process(BillingFixtures.update(mine, counter: FinishCounter()))
            XCTAssertEqual(info.source, .server, "status \(status)")
            XCTAssertNil(info.entitlements["gold"], "another user's tagged purchase stays locked (status \(status))")
            XCTAssertEqual(info.entitlements["premium"]?.isActive, true, "the buyer keeps theirs (status \(status))")
        }
    }

    func testTotalOutageStillUnlocksEveryVerifiedPurchase() async {
        let othersPurchase = BillingFixtures.transaction(id: "2000000000000009", productId: "pro_yearly",
                                                         appAccountToken: BillingFixtures.otherAccountToken)
        let mine = BillingFixtures.transaction(id: "2000000000000002", productId: "pro_monthly")
        let engine = env.engine(
            transport: MockBillingTransport.unreachable(), storeKit: FakeStoreKit(entitlements: [othersPurchase, mine]),
            options: mapping, appUserId: "user_b"
        )
        let info = await engine.process(BillingFixtures.update(mine, counter: FinishCounter()))
        XCTAssertEqual(info.source, .localFallback)
        XCTAssertEqual(info.entitlements["gold"]?.isActive, true)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
    }

    func testFailedRestoreWhileAppReferAnswersUsesFilteredAnswer() async throws {
        let othersPurchase = BillingFixtures.transaction(id: "2000000000000009", productId: "pro_yearly",
                                                         appAccountToken: BillingFixtures.otherAccountToken)
        let transport = MockBillingTransport { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(#"{"error":"bad"}"#.utf8), 400) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_b").utf8), 200)
        }
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: [othersPurchase]),
            options: mapping, appUserId: "user_b"
        )
        let info = try await engine.restore()
        XCTAssertEqual(info.source, .server)
        XCTAssertNil(info.entitlements["gold"])
    }

    // MARK: - Restore ownership in the queue

    func testExplicitRestoreTakesOverQueuedEntryAndRedeliveryNeverRewritesIt() {
        let queue = env.queue()
        queue.add(entry(user: "user_a"))
        queue.add(entry(user: "user_b", restore: true))
        XCTAssertEqual(queue.entries.first?.appUserId, "user_b")
        XCTAssertEqual(queue.entries.first?.restore, true)

        queue.add(entry(user: "user_a"))
        XCTAssertEqual(queue.entries.first?.appUserId, "user_b", "an ordinary redelivery never takes a restore")
        XCTAssertEqual(queue.entries.first?.restore, true)
        XCTAssertEqual(env.queue().entries.first?.appUserId, "user_b", "persisted")
    }

    func testOfflineRestoreByAnotherUserMovesQueuedEntryToThem() async throws {
        let transaction = BillingFixtures.transaction()
        let queue = env.queue()
        queue.add(entry(user: "user_a"))
        let transport = MockBillingTransport.unreachable()
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: [transaction]), appUserId: "user_b", queue: queue
        )
        _ = try await engine.restore()
        XCTAssertEqual(queue.entries.map(\.appUserId), ["user_b"])
        XCTAssertEqual(queue.entries.first?.restore, true)

        transport.setHandler { _ in (Data(BillingFixtures.customerJSON(appUserId: "user_b").utf8), 200) }
        await engine.drainQueue()
        let body = try XCTUnwrap(transport.requests(to: purchasesPath).last?.jsonBody)
        XCTAssertEqual(body["appUserId"] as? String, "user_b")
        XCTAssertEqual(body["restore"] as? Bool, true)
    }

    func testPausedRestoreQueuesTheRestOfTheBatchUnsent() async throws {
        let transactions = (1...3).map { BillingFixtures.transaction(id: "200000000000000\($0)") }
        let transport = MockBillingTransport { _ in (Data(#"{"error":"rate limited"}"#.utf8), 429) }
        let queue = env.queue()
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: transactions), appUserId: "user_1", queue: queue
        )
        _ = try await engine.restore()
        XCTAssertEqual(transport.requests(to: purchasesPath).count, 1, "nothing else sent while paused")
        XCTAssertEqual(queue.entries.map(\.transactionId), transactions.map(\.id))
        XCTAssertTrue(queue.entries.allSatisfy { $0.restore == true && $0.attempts == 0 && $0.appUserId == "user_1" })
    }

    // MARK: - Identity minting

    func testKeychainReadFailureNeverMintsAnonymousId() async {
        let storage = env.storage()
        env.secure.readFailure = errSecInternalError
        XCTAssertEqual(storage.storedAnonymousId, .unknown)
        XCTAssertNil(storage.anonymousId())
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "x"))
        let engine = env.engine(transport: transport, storage: storage)
        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertTrue(transport.requests.isEmpty, "unknown identity: nothing sent")

        env.secure.readFailure = nil
        XCTAssertEqual(storage.storedAnonymousId, .absent)
    }

    func testUnsavedAnonymousIdIsNeverReturned() {
        let storage = env.storage()
        env.secure.failWrites = true
        XCTAssertNil(storage.anonymousId())
        XCTAssertNil(storage.resetAnonymousId())
        env.secure.failWrites = false
        let id = storage.anonymousId()
        XCTAssertNotNil(id)
        XCTAssertEqual(storage.anonymousId(), id)
    }

    func testLogOutWaitsUntilTheNewAnonymousIdIsSaved() async throws {
        let storage = env.storage()
        let engine = env.engine(transport: MockBillingTransport.unreachable(), storage: storage)
        _ = try await engine.logIn("user_1")
        env.secure.failWrites = true
        let info = await engine.logOut()
        XCTAssertEqual(info.appUserId, "", "no usable identity yet")
        let whileFailing = await engine.currentAppUserId
        XCTAssertEqual(whileFailing, "")

        env.secure.failWrites = false
        let user = await engine.currentAppUserId
        XCTAssertTrue(BillingStorage.isAnonymous(user))
        XCTAssertNil(storage.loggedInAppUserId)
    }

    func testDeviceIdIsNotMintedOnReadFailureOrReturnedUnsaved() {
        let keychain = ScriptedDeviceIdKeychain()
        keychain.readResult = .failed(errSecInternalError)
        XCTAssertNil(AppReferStorage(keychain: keychain).deviceId())
        XCTAssertEqual(keychain.addCalls, 0)

        keychain.readResult = .notFound
        keychain.addStatus = errSecInternalError
        XCTAssertNil(AppReferStorage(keychain: keychain).deviceId(), "never return an id that wasn't saved")
    }

    func testConcurrentFetchesShareOneIdentifyFlush() async {
        let storage = env.storage()
        storage.addPendingIdentify(anonymousId: "$ARAnon:6F9619FF-8B86-D011-B42D-00C04FC964FF", appUserId: "user_1")
        storage.loggedInAppUserId = "user_1"
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, storage: storage)

        async let first = engine.customerInfo(policy: .fetchCurrent)
        async let second = engine.customerInfo(policy: .fetchCurrent)
        _ = await (first, second)
        XCTAssertEqual(transport.requests(to: "/api/billing/v1/identify").count, 1)
        XCTAssertTrue(storage.pendingIdentifies.isEmpty)
    }

    // MARK: - Retry-After

    func testRetryAfterIsParsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(BillingAPIClient.parseRetryAfter("120", now: now), 120)
        XCTAssertEqual(BillingAPIClient.parseRetryAfter(" 0 ", now: now), 0)
        XCTAssertNil(BillingAPIClient.parseRetryAfter("-5", now: now))
        XCTAssertNil(BillingAPIClient.parseRetryAfter("soon", now: now))
        XCTAssertNil(BillingAPIClient.parseRetryAfter(nil, now: now))
        // 1_800_000_090 = Fri, 15 Jan 2027 08:01:30 GMT
        XCTAssertEqual(BillingAPIClient.parseRetryAfter("Fri, 15 Jan 2027 08:01:30 GMT", now: now), 90)
    }

    func testRetryAfterReachesTheEngineAndPausesWithoutSpendingAttempts() async {
        let queue = env.queue()
        queue.add(entry())
        let clock = TestClock()
        let transport = MockBillingTransport { _ in (Data(#"{"error":"not recorded"}"#.utf8), 503) }
        transport.retryAfter = "120"
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue, now: { clock.now })

        await engine.drainQueue()
        let sent = transport.requests(to: purchasesPath).count
        XCTAssertEqual(queue.entries.first?.attempts, 0, "a server-requested wait doesn't count")

        clock.advance(60)
        await engine.drainQueue()
        XCTAssertEqual(transport.requests(to: purchasesPath).count, sent, "paused for Retry-After")

        clock.advance(61)
        await engine.drainQueue()
        XCTAssertGreaterThan(transport.requests(to: purchasesPath).count, sent)
        XCTAssertEqual(queue.entries.count, 1, "kept until recorded")
    }

    func testRetryAfterOnAPurchaseKeepsItQueuedAndPausesTheDrain() async {
        let clock = TestClock()
        let transport = MockBillingTransport { request in
            if request.url?.path == "/api/billing/v1/purchases" { return (Data(), 503) }
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: "user_1").utf8), 200)
        }
        transport.retryAfter = "300"
        let queue = env.queue()
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue, now: { clock.now })
        let counter = FinishCounter()
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: counter))
        XCTAssertEqual(counter.count, 1, "durably queued")
        XCTAssertEqual(queue.entries.first?.attempts, 0)
        let sent = transport.requests(to: purchasesPath).count

        clock.advance(100)
        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(transport.requests(to: purchasesPath).count, sent)
    }

    // MARK: - Legacy 200 with conversion "failed"

    func testLegacyFailedConversionIsRetryable() async {
        let json = BillingFixtures.customerJSON(appUserId: "user_1").dropLast()
            + #","purchase":{"productId":"pro_yearly","state":"active","conversion":"failed"}}"#
        let transport = MockBillingTransport.ok(String(json))
        let client = BillingAPIClient(baseURLs: ["https://trk.example.com"], apiKey: { "pk" }, transport: transport, keyWaitAttempts: 0)
        do {
            _ = try await client.send(.purchase(appUserId: "user_1", appreferId: nil, signedTransaction: "x", attributes: [:], restore: false))
            XCTFail("expected error")
        } catch let error as AppReferBillingError {
            XCTAssertTrue(error.isRetryable)
            XCTAssertEqual(error.retryAfter, BillingAPIClient.defaultRetryAfter)
        } catch {
            XCTFail("\(error)")
        }
        // Customer reads and recorded purchases are unaffected.
        _ = try? await client.send(.getCustomer(appUserId: "user_1"))
        let recorded = BillingFixtures.customerJSON(appUserId: "user_1").dropLast() + #","purchase":{"conversion":"none"}}"#
        transport.setHandler { _ in (Data(String(recorded).utf8), 200) }
        let response = try? await client.send(.purchase(appUserId: "user_1", appreferId: nil, signedTransaction: "x", attributes: [:], restore: false))
        XCTAssertNotNil(response)

        let queue = env.queue()
        transport.setHandler { _ in (Data(String(json).utf8), 200) }
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue)
        let counter = FinishCounter()
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: counter))
        XCTAssertEqual(queue.entries.map(\.transactionId), ["2000000000000001"], "kept for retry")
        XCTAssertEqual(counter.count, 1, "finished only because the retry copy is on disk")
    }
}

final class ScriptedDeviceIdKeychain: DeviceIdKeychain, @unchecked Sendable {
    var readResult: KeychainReadResult = .notFound
    var addStatus: OSStatus = errSecSuccess
    private(set) var addCalls = 0

    func load(key: String) -> KeychainReadResult { readResult }
    func add(key: String, value: String) -> OSStatus {
        addCalls += 1
        return addStatus
    }
}
