import XCTest
@testable import AppRefer

private actor ImportGate {
    var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(_ entered: XCTestExpectation? = nil) async {
        reached = true
        await withCheckedContinuation { continuation = $0; entered?.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class BillingMigrationReviewTests: XCTestCase {
    func testOpenPurchasesSkipImportAndOldMarkerDoesNotBlockProcessing() async {
        let env = BillingTestEnvironment()
        let storage = env.storage()
        let transaction = BillingFixtures.transaction()
        let store = FakeStoreKit(entitlements: [transaction]), counter = FinishCounter()
        store.unfinished = [BillingFixtures.update(transaction, counter: counter)]
        _ = storage.markMigrationPurchase(transaction.id)
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "alice"))
        let engine = env.engine(transport: transport, storeKit: store, appUserId: "alice", storage: storage)
        await engine.migrationSync()
        XCTAssertTrue(transport.requests(to: "/api/billing/v1/purchases").isEmpty)
        _ = await engine.process(store.unfinished[0])
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(transport.requests(to: "/api/billing/v1/purchases").count, 1)
    }

    func testImportRespectsCurrentForeignAndUnknownTokens() async {
        let env = BillingTestEnvironment()
        let storage = env.storage()
        let mine = BillingFixtures.accountToken, foreign = BillingFixtures.otherAccountToken
        storage.setAccountToken(mine.uuidString, for: "alice")
        storage.setAccountToken(foreign.uuidString, for: "bob")
        let store = FakeStoreKit(entitlements: [
            BillingFixtures.transaction(id: "untagged"),
            BillingFixtures.transaction(id: "mine", appAccountToken: mine),
            BillingFixtures.transaction(id: "foreign", appAccountToken: foreign),
            BillingFixtures.transaction(id: "unknown", appAccountToken: UUID()),
        ])
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "alice"))
        let engine = env.engine(transport: transport, storeKit: store, appUserId: "alice", storage: storage)
        await engine.migrationSync()
        XCTAssertEqual(transport.requests(to: "/api/billing/v1/purchases").count, 2)
    }

    func testPartialProgressSurvivesRestartAndRetriesOnlyLeftover() async {
        let env = BillingTestEnvironment()
        let storage = env.storage()
        let good = BillingFixtures.transaction(id: "good"), leftover = BillingFixtures.transaction(id: "leftover")
        let store = FakeStoreKit(entitlements: [good, leftover])
        store.unfinished = [BillingFixtures.update(leftover, counter: FinishCounter())]
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "alice"))
        let first = env.engine(transport: transport, storeKit: store, appUserId: "alice", storage: storage)
        await first.migrationSync()
        XCTAssertFalse(storage.migrationSynced("alice"))
        let reloaded = env.storage()
        let second = env.engine(transport: transport, storeKit: store, appUserId: "alice", storage: reloaded)
        await second.migrationSync()
        XCTAssertEqual(transport.requests(to: "/api/billing/v1/purchases").count, 1)
        store.unfinished = []
        await second.migrationSync()
        XCTAssertEqual(transport.requests(to: "/api/billing/v1/purchases").count, 2)
        XCTAssertTrue(reloaded.migrationSynced("alice"))
    }

    func testStaleExplicitUserAndSwitchDuringQueryAbort() async {
        let env = BillingTestEnvironment()
        let storage = env.storage()
        let store = FakeStoreKit(entitlements: [BillingFixtures.transaction()])
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "alice"))
        let engine = env.engine(transport: transport, storeKit: store, appUserId: "alice", storage: storage)
        await engine.migrationSync(forUser: "bob")
        XCTAssertFalse(storage.migrationSynced("bob"))
        store.onEntitlements = { storage.loggedInAppUserId = "bob" }
        await engine.migrationSync(forUser: "alice")
        XCTAssertTrue(transport.requests(to: "/api/billing/v1/purchases").isEmpty)
        XCTAssertFalse(storage.migrationSynced("alice"))
    }

    func testRejectedImportUsesRealIdAndRestoreSendsOnce() async throws {
        let env = BillingTestEnvironment()
        let transaction = BillingFixtures.transaction(id: "legacy")
        let store = FakeStoreKit(entitlements: [transaction])
        let transport = MockBillingTransport { _ in (Data("{}".utf8), 422) }
        let engine = env.engine(transport: transport, storeKit: store, appUserId: "alice")
        await engine.migrationSync()
        let rejected = await engine.rejectedPurchases()
        XCTAssertEqual(rejected.first?.transactionId, "legacy")
        XCTAssertEqual(rejected.first?.migrationOnly, true)
        transport.setHandler { _ in (Data(BillingFixtures.emptyCustomerJSON(appUserId: "alice").utf8), 200) }
        let before = transport.requests(to: "/api/billing/v1/purchases").count
        _ = try await engine.restore()
        XCTAssertEqual(transport.requests(to: "/api/billing/v1/purchases").count - before, 1)
        let remaining = await engine.rejectedPurchases()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testStartFetchesBeforeNonblockingImport() async {
        let env = BillingTestEnvironment(), gate = ImportGate()
        let store = FakeStoreKit()
        let entered = expectation(description: "background import reached store")
        store.onEntitlements = {
            if store.unfinishedCalls > 1 { await gate.wait(entered) }
        }
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "alice"))
        let engine = env.engine(transport: transport, storeKit: store, appUserId: "alice")
        // Only the import's store query waits; the initial refresh is allowed to finish.
        await engine.start()
        XCTAssertFalse(transport.requests.isEmpty)
        await fulfillment(of: [entered], timeout: 3)
        let reached = await gate.reached
        XCTAssertTrue(reached)
        await gate.release()
    }
}
