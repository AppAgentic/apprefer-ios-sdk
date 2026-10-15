import XCTest
@testable import AppRefer

final class BillingMigrationTests: XCTestCase {
    func testImportIsDurableOncePerUserWithoutRestoreOrFinish() async throws {
        let env = BillingTestEnvironment()
        let storage = env.storage()
        let store = FakeStoreKit(entitlements: [BillingFixtures.transaction()])
        let transport = MockBillingTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data("{}".utf8)) as? [String: Any]
            let user = body?["appUserId"] as? String ?? "alice"
            return (Data(BillingFixtures.emptyCustomerJSON(appUserId: user).utf8), 200)
        }
        let engine = env.engine(transport: transport, storeKit: store, appUserId: "alice", storage: storage)
        await engine.migrationSync()
        XCTAssertTrue(storage.migrationSynced("alice"))
        await engine.migrationSync()
        XCTAssertEqual(transport.requests(to: "/api/billing/v1/purchases").count, 1)
        XCTAssertEqual(store.syncCalls, 0)
        _ = try await engine.logIn("bob")
        for _ in 0..<100 where !storage.migrationSynced("bob") {
            await engine.migrationSync()
            await Task.yield()
        }
        XCTAssertTrue(storage.migrationSynced("bob"))
        let bodies = try transport.requests(to: "/api/billing/v1/purchases").map {
            try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any]
        }
        XCTAssertEqual(Set(bodies.compactMap { $0["appUserId"] as? String }), ["alice", "bob"])
        XCTAssertTrue(bodies.allSatisfy { $0["restore"] == nil })
    }

    func testFailedQueueWriteDoesNotSetFlagAndRetryDoesNotFinish() async {
        let env = BillingTestEnvironment()
        let storage = env.storage()
        let store = FakeStoreKit(entitlements: [BillingFixtures.transaction(kind: .consumable)])
        let blocked = env.directory.appendingPathComponent("blocked")
        try! FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let queue = PendingPurchaseQueue(fileURL: blocked)
        let engine = env.engine(transport: MockBillingTransport.unreachable(), storeKit: store,
                                appUserId: "alice", storage: storage, queue: queue)
        await engine.migrationSync()
        XCTAssertFalse(storage.migrationSynced("alice"))
        XCTAssertEqual(store.syncCalls, 0)
        XCTAssertEqual(queue.entries.count, 1)
    }

    func testOfflineImportSetsFlagOnlyAfterDurableQueueAndReplayHasNoFinish() async {
        let env = BillingTestEnvironment()
        let storage = env.storage()
        let queue = env.queue()
        let transport = MockBillingTransport.unreachable()
        let store = FakeStoreKit(entitlements: [BillingFixtures.transaction()])
        let engine = env.engine(transport: transport, storeKit: store, appUserId: "alice", storage: storage, queue: queue)
        await engine.migrationSync()
        XCTAssertTrue(storage.migrationSynced("alice"))
        XCTAssertTrue(queue.isDurable(transactionId: queue.entries[0].transactionId))
        let reloaded = env.queue()
        XCTAssertEqual(reloaded.entries.count, 1)
        transport.setHandler { _ in (Data(BillingFixtures.emptyCustomerJSON(appUserId: "alice").utf8), 200) }
        await engine.drainQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(store.syncCalls, 0)
    }
    func testStartupAndRestartProcessOpenTransactionsNormally() async {
        let env = BillingTestEnvironment()
        let store = FakeStoreKit(entitlements: [BillingFixtures.transaction()])
        let counter = FinishCounter()
        store.unfinished = [BillingFixtures.update(store.entitlements[0], counter: counter)]
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: "alice"))
        let first = env.engine(transport: transport, storeKit: store, appUserId: "alice")
        await first.start()
        let second = env.engine(transport: transport, storeKit: store, appUserId: "alice")
        await second.start()
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(transport.requests(to: "/api/billing/v1/purchases").count, 2)
    }

    func testMigrationBackoffKeepsEveryImportDurableWithoutRestore() async {
        for status in [401, 403, 404, 409, 429] {
            let env = BillingTestEnvironment()
            let storage = env.storage()
            let queue = env.queue()
            let store = FakeStoreKit(entitlements: [BillingFixtures.transaction(id: "one"), BillingFixtures.transaction(id: "two")])
            let transport = MockBillingTransport { _ in (Data("{}".utf8), status) }
            let engine = env.engine(transport: transport, storeKit: store, appUserId: "alice", storage: storage, queue: queue)
            await engine.migrationSync()
            XCTAssertTrue(storage.migrationSynced("alice"))
            XCTAssertEqual(queue.entries.count, 2)
            XCTAssertTrue(queue.entries.allSatisfy { $0.attempts == 0 && $0.restore != true && queue.isDurable(transactionId: $0.transactionId) })
            let sent = transport.requests.count
            await engine.drainQueue()
            XCTAssertEqual(transport.requests.count, sent)
            XCTAssertEqual(store.syncCalls, 0)
        }
    }

}
