import XCTest
@testable import AppRefer

/// Regression tests for the AppRefer Billing review (Oct 2026): StoreKit merge,
/// retry back-off, restore-only ownership transfer, locked Keychain, pending identifies.
final class BillingReviewFixesTests: XCTestCase {
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

    // MARK: - #2 StoreKit entitlements merged into server answers

    func testServerWithoutPurchaseStillUnlocksTokenlessStoreKitPurchase() async {
        // The upload was dropped/rejected and the App Store notification had no token,
        // so the server never learned of it. Nothing is queued.
        let storeKit = FakeStoreKit(entitlements: [BillingFixtures.transaction(appAccountToken: nil)])
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_1"))
        let queue = env.queue()
        let engine = env.engine(transport: transport, storeKit: storeKit, appUserId: "user_1", queue: queue)

        let info = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(info.source, .server)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
    }

    func testStoreKitPurchaseWithCurrentUsersTokenIsMerged() async {
        let storeKit = FakeStoreKit(entitlements: [BillingFixtures.transaction(appAccountToken: BillingFixtures.accountToken)])
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, storeKit: storeKit, appUserId: "user_1")

        let info = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
    }

    func testStoreKitPurchaseOfAnotherAppUserIsNotMergedIntoServerAnswer() async {
        let storeKit = FakeStoreKit(entitlements: [BillingFixtures.transaction(appAccountToken: BillingFixtures.otherAccountToken)])
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, storeKit: storeKit, appUserId: "user_1")

        let info = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertNil(info.entitlements["premium"], "the server knows whose purchase this is")
    }

    // MARK: - #2 retry queue back-off

    private func queuedEntry(attempts: Int = 1, restore: Bool? = nil) -> PendingPurchase {
        PendingPurchase(
            transactionId: "2000000000000001", productId: "pro_yearly", appUserId: "user_1", appreferId: nil,
            signedTransaction: "jws.2000000000000001.sig", enqueuedAt: BillingFixtures.now, attempts: attempts,
            restore: restore
        )
    }

    func testBackoffStatusesKeepPurchaseWithoutUsingAttempts() async {
        for status in [401, 404, 409, 429] {
            let local = BillingTestEnvironment()
            defer { local.cleanUp() }
            let queue = local.queue()
            queue.add(queuedEntry())
            let clock = TestClock()
            let transport = MockBillingTransport { _ in (Data(#"{"error":"not now"}"#.utf8), status) }
            let engine = local.engine(transport: transport, appUserId: "user_1", queue: queue, now: { clock.now })

            for _ in 0..<10 { await engine.drainQueue() }
            XCTAssertEqual(queue.entries.first?.attempts, 1, "status \(status) must not count attempts")
            XCTAssertEqual(transport.requests(to: purchasesPath).count, 1, "status \(status) backs off")

            clock.advance(BillingEngine.minBackoff + 1)
            await engine.drainQueue()
            XCTAssertEqual(transport.requests(to: purchasesPath).count, 2, "retried after back-off")
            XCTAssertEqual(queue.entries.count, 1)
            XCTAssertEqual(queue.entries.first?.attempts, 1)

            clock.advance(BillingEngine.minBackoff + 1)
            await engine.drainQueue()
            XCTAssertEqual(transport.requests(to: purchasesPath).count, 2, "back-off doubles")
        }
    }

    func testBackoffEndsWhenServerAcceptsAgain() async {
        let queue = env.queue()
        queue.add(queuedEntry())
        let clock = TestClock()
        let transport = MockBillingTransport { _ in (Data(#"{"error":"Apple billing is not configured"}"#.utf8), 409) }
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue, now: { clock.now })
        await engine.drainQueue()

        transport.setHandler { _ in (Data(BillingFixtures.customerJSON(appUserId: "user_1").utf8), 200) }
        clock.advance(BillingEngine.minBackoff + 1)
        await engine.drainQueue()
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - #3 restore flag

    func testPurchasesAndUpdatesNeverSendRestore() async throws {
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, appUserId: "user_1")

        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()))
        let body = try XCTUnwrap(transport.requests(to: purchasesPath).last?.jsonBody)
        XCTAssertNil(body["restore"])
    }

    func testRestoreSendsRestoreTrueAndKeepsItWhenQueued() async throws {
        let transaction = BillingFixtures.transaction()
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let queue = env.queue()
        let engine = env.engine(
            transport: transport, storeKit: FakeStoreKit(entitlements: [transaction]), appUserId: "user_1", queue: queue
        )

        _ = try await engine.restore()
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["restore"] as? Bool, true)

        // Offline restore: the queued retry is still a restore.
        transport.setHandler { _ in throw AppReferBillingError.network("offline") }
        _ = try await engine.restore()
        XCTAssertEqual(queue.entries.first?.restore, true)
        XCTAssertEqual(env.queue().entries.first?.restore, true, "persisted")

        transport.setHandler { _ in (Data(BillingFixtures.customerJSON(appUserId: "user_1").utf8), 200) }
        await engine.drainQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(transport.requests(to: purchasesPath).last?.jsonBody?["restore"] as? Bool, true)
    }

    func testQueuedNonRestoreRetryOmitsRestore() async throws {
        let queue = env.queue()
        queue.add(queuedEntry())
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, appUserId: "user_1", queue: queue)

        await engine.drainQueue()
        let body = try XCTUnwrap(transport.requests(to: purchasesPath).last?.jsonBody)
        XCTAssertNil(body["restore"])
    }

    func testRequeuingARestoreKeepsTheRestoreFlag() {
        let queue = env.queue()
        queue.add(queuedEntry(restore: true))
        queue.add(queuedEntry(restore: nil))
        XCTAssertEqual(queue.entries.first?.restore, true)
    }

    // MARK: - #5 protected data unavailable (before first unlock)

    func testLockedKeychainSkipsNetworkAndNeverMintsAnonymousId() async {
        let storage = env.storage()
        let anon = storage.anonymousId()
        env.secure.isLocked = true
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "x"))
        let storeKit = FakeStoreKit(entitlements: [BillingFixtures.transaction()])
        let engine = env.engine(transport: transport, storeKit: storeKit, storage: storage)

        let info = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true, "StoreKit still answers")
        XCTAssertEqual(info.appUserId, "")
        let token = await engine.accountToken()
        XCTAssertNil(token)
        XCTAssertTrue(transport.requests.isEmpty)

        env.secure.isLocked = false
        XCTAssertEqual(storage.anonymousId(), anon, "the real id survived")
    }

    func testTransactionWhileLockedIsDeferredUnfinishedThenSent() async {
        let storage = env.storage()
        _ = storage.anonymousId()
        storage.loggedInAppUserId = "user_1"
        env.secure.isLocked = true
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: transport, storage: storage)
        let counter = FinishCounter()

        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: counter))
        XCTAssertEqual(counter.count, 0, "left unfinished so StoreKit keeps it")
        XCTAssertTrue(transport.requests.isEmpty)

        env.secure.isLocked = false
        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(counter.count, 1)
        let post = transport.requests(to: purchasesPath).first
        XCTAssertEqual(post?.jsonBody?["appUserId"] as? String, "user_1", "sent as the real user")
    }

    func testConfigureWhileLockedAppliesUserOnceUnlocked() async {
        let storage = env.storage()
        let anon = storage.anonymousId()
        env.secure.isLocked = true
        let transport = MockBillingTransport.unreachable()
        let engine = env.engine(transport: transport, appUserId: "user_1", storage: storage)
        XCTAssertNil(storage.loggedInAppUserId)

        env.secure.isLocked = false
        let user = await engine.currentAppUserId
        XCTAssertEqual(user, "user_1")
        XCTAssertEqual(storage.pendingIdentifies, [.init(anonymousId: anon!, appUserId: "user_1")])
    }

    // MARK: - #6 pending identifies survive logOut

    func testPendingIdentifySurvivesLogOutAndIsFlushedLater() async throws {
        let storage = env.storage()
        let anon = try XCTUnwrap(storage.anonymousId())
        let transport = MockBillingTransport.unreachable()
        let engine = env.engine(transport: transport, storage: storage)

        _ = try await engine.logIn("user_1")
        _ = await engine.logOut()
        XCTAssertEqual(storage.pendingIdentifies, [.init(anonymousId: anon, appUserId: "user_1")])

        let secondAnon = try XCTUnwrap(storage.anonymousId())
        _ = try await engine.logIn("user_2")
        XCTAssertEqual(storage.pendingIdentifies.map(\.appUserId), ["user_1", "user_2"])

        let offlineCount = transport.requests(to: "/api/billing/v1/identify").count
        transport.setHandler { _ in (Data(BillingFixtures.customerJSON(appUserId: "user_2").utf8), 200) }
        _ = await engine.customerInfo(policy: .fetchCurrent)
        let identifies = transport.requests(to: "/api/billing/v1/identify").dropFirst(offlineCount).compactMap(\.jsonBody)
        XCTAssertEqual(identifies.map { $0["anonymousId"] as? String }, [anon, secondAnon])
        XCTAssertEqual(identifies.map { $0["appUserId"] as? String }, ["user_1", "user_2"])
        XCTAssertTrue(storage.pendingIdentifies.isEmpty)
    }

    func testIdentifyFlushStopsAtFirstRetryableFailure() async throws {
        let storage = env.storage()
        storage.addPendingIdentify(anonymousId: "$ARAnon:6F9619FF-8B86-D011-B42D-00C04FC964FF", appUserId: "user_1")
        storage.addPendingIdentify(anonymousId: "$ARAnon:7F9619FF-8B86-D011-B42D-00C04FC964FF", appUserId: "user_2")
        storage.loggedInAppUserId = "user_2"
        let transport = MockBillingTransport { request in
            if request.url?.path == "/api/billing/v1/identify" { return (Data(), 503) }
            return (Data(BillingFixtures.customerJSON(appUserId: "user_2").utf8), 200)
        }
        let engine = env.engine(transport: transport, storage: storage)

        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(storage.pendingIdentifies.count, 2)
        // 503 fails over to the second host, then stops: user_2's identify is not tried first.
        let identifies = transport.requests(to: "/api/billing/v1/identify").compactMap { $0.jsonBody?["appUserId"] as? String }
        XCTAssertEqual(Set(identifies), ["user_1"])
    }

    // MARK: - #9 free trials on iOS 15–17.1

    func testLegacyPeriodTypeReportsFreeTrial() {
        let trial = Data(#"{"offerType":1,"offerDiscountType":"FREE_TRIAL"}"#.utf8)
        let paid = Data(#"{"offerType":1,"offerDiscountType":"PAY_AS_YOU_GO"}"#.utf8)
        let unknown = Data(#"{"offerType":1}"#.utf8)
        XCTAssertEqual(LiveBillingStoreKit.legacyPeriodType(offer: .introductory, signedPayload: trial), .trial)
        XCTAssertEqual(LiveBillingStoreKit.legacyPeriodType(offer: .introductory, signedPayload: paid), .intro)
        XCTAssertEqual(LiveBillingStoreKit.legacyPeriodType(offer: .introductory, signedPayload: unknown), .intro)
        XCTAssertEqual(LiveBillingStoreKit.legacyPeriodType(offer: .promotional, signedPayload: trial), .promotional)
        XCTAssertEqual(LiveBillingStoreKit.legacyPeriodType(offer: .none, signedPayload: Data()), .normal)
    }
}

// MARK: - #4 device id get-or-mint

/// Keychain fake with a slow read, so an unlocked get-or-mint would race.
final class FakeDeviceIdKeychain: DeviceIdKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var locked = false
    /// Simulates another process adding an item between our read and our add.
    var preemptValue: String?
    private(set) var addCalls = 0

    func load(key: String) -> KeychainReadResult {
        lock.lock()
        let isLocked = locked
        let value = values[key]
        lock.unlock()
        if isLocked { return .unavailable(errSecInteractionNotAllowed) }
        usleep(2000)
        return value.map { .found($0) } ?? .notFound
    }

    func add(key: String, value: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        addCalls += 1
        if let preempt = preemptValue {
            values[key] = preempt
            preemptValue = nil
        }
        if values[key] != nil { return errSecDuplicateItem }
        values[key] = value
        return errSecSuccess
    }

    /// Simulates a Keychain that can't save (e.g. no entitlement).
    var failSaves = false

    func save(key: String, value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if locked || failSaves { return false }
        values[key] = value
        return true
    }

    func delete(key: String) {
        lock.lock()
        values[key] = nil
        lock.unlock()
    }

    func value(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
}

final class DeviceIdTests: XCTestCase {
    func testConcurrentFirstLaunchCallsShareOneDeviceId() {
        let keychain = FakeDeviceIdKeychain()
        let ids = NSMutableSet()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            // Attribution and billing each make their own storage.
            let id = AppReferStorage(keychain: keychain).deviceId()
            lock.lock()
            ids.add(id as Any)
            lock.unlock()
        }
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(keychain.addCalls, 1, "minted once, never delete-then-add")
    }

    func testDuplicateItemOnAddRereadsTheStoredId() {
        let keychain = FakeDeviceIdKeychain()
        keychain.preemptValue = "from-extension"
        XCTAssertEqual(AppReferStorage(keychain: keychain).deviceId(), "from-extension")
        XCTAssertEqual(AppReferStorage(keychain: keychain).deviceId(), "from-extension")
    }

    func testLockedKeychainReturnsNilInsteadOfMinting() {
        let keychain = FakeDeviceIdKeychain()
        let original = AppReferStorage(keychain: keychain).deviceId()
        keychain.locked = true
        XCTAssertNil(AppReferStorage(keychain: keychain).deviceId())
        keychain.locked = false
        XCTAssertEqual(AppReferStorage(keychain: keychain).deviceId(), original)
        XCTAssertEqual(keychain.addCalls, 1)
    }
}
