import Foundation
import XCTest
@testable import AppRefer

private final class EnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BillingEnvironment = .production
    var value: BillingEnvironment {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

final class BillingEnvironmentEngineTests: XCTestCase {
    private func transaction(_ environment: String?, product: String) throws -> StoreTransaction {
        let payload = try JSONSerialization.data(withJSONObject: environment.map { ["environment": $0] } ?? [:]).base64EncodedString()
        return StoreTransaction(id: product, originalId: "orig-\(product)", productId: product, kind: .autoRenewable,
            purchaseDate: BillingFixtures.now, expirationDate: BillingFixtures.now.addingTimeInterval(86400), revocationDate: nil,
            isUpgraded: false, periodType: .normal, signedTransaction: "a.\(payload).s")
    }

    func testReplayChecksCurrentScopeBeforeGranting() async throws {
        let box = EnvironmentBox()
        let broadcaster = CustomerInfoBroadcaster()
        broadcaster.setValidator { $0.environment == box.value }
        func info(_ scope: BillingEnvironment) -> AppReferCustomerInfo {
            AppReferCustomerInfo(appUserId: "same-user", entitlements: .init([:]), activeSubscriptions: [scope.rawValue], requestDate: BillingFixtures.now, source: .server, environment: scope)
        }
        var iterator = broadcaster.stream().makeAsyncIterator()
        broadcaster.publish(info(.production))
        box.value = .sandbox
        broadcaster.publish(info(.sandbox))
        let replayed = await iterator.next()
        XCTAssertEqual(replayed?.environment, .sandbox)
        XCTAssertEqual(replayed?.activeSubscriptions, ["sandbox"])
    }

    func testCacheAndLocalStoreRemainScopedAcrossChanges() async throws {
        let env = BillingTestEnvironment()
        let box = EnvironmentBox()
        let storage = env.storage()
        var cached = try JSONSerialization.jsonObject(with: Data(BillingFixtures.customerJSON(appUserId: "same-user").utf8)) as! [String: Any]
        cached["environment"] = "sandbox"
        storage.setCachedCustomerInfo(try JSONDecoder().decode(AppReferCustomerInfo.self, from: JSONSerialization.data(withJSONObject: cached)))
        let store = FakeStoreKit(entitlements: [try transaction("Production", product: "prod"), try transaction("Sandbox", product: "test"), try transaction(nil, product: "unknown")])
        let engine = env.engine(transport: MockBillingTransport.unreachable(), storeKit: store,
            options: .init(environment: { box.value }), appUserId: "same-user", storage: storage, apiKey: "pk_live_a")
        await engine.start()
        let production = await engine.localFallback()
        XCTAssertEqual(production.activeSubscriptions, ["prod"])
        XCTAssertEqual(production.environment, .production)
        box.value = .sandbox
        let sandbox = await engine.localFallback()
        XCTAssertTrue(sandbox.activeSubscriptions.contains("test"))
        XCTAssertFalse(sandbox.activeSubscriptions.contains("prod"))
        XCTAssertFalse(sandbox.activeSubscriptions.contains("unknown"))
        XCTAssertEqual(sandbox.environment, .sandbox)
    }

    func testLegacyQueuedProofIsRetainedForItsVerifiedEnvironmentWithoutBlockingNext() async throws {
        let env = BillingTestEnvironment()
        let box = EnvironmentBox()
        let queue = env.queue()
        let storage = env.storage()
        let transport = MockBillingTransport { request in
            let scope = request.value(forHTTPHeaderField: "X-AppRefer-Billing-Environment")!
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if body?["signedTransaction"] as? String == "old-sandbox-proof" && scope == "production" {
                return (Data(#"{"error":"scope mismatch","code":"billing_environment_mismatch","environment":"sandbox"}"#.utf8), 400)
            }
            return (try JSONSerialization.data(withJSONObject: ["appUserId": "same-user", "environment": scope, "entitlements": [:], "activeSubscriptions": []]), 200)
        }
        let engine = env.engine(transport: transport, options: .init(environment: { box.value }), appUserId: "same-user", storage: storage, queue: queue, apiKey: "pk_live_a")
        for (id, proof) in [("legacy", "old-sandbox-proof"), ("production", "production-proof")] {
            XCTAssertTrue(queue.add(PendingPurchase(transactionId: id, productId: "plan", appUserId: "same-user", appreferId: nil, signedTransaction: proof, enqueuedAt: Date(timeIntervalSince1970: 0), attempts: 999)))
        }
        await engine.drainQueue()
        XCTAssertNotNil(queue.entry(transactionId: "legacy"))
        XCTAssertNil(queue.entry(transactionId: "production"))
        XCTAssertEqual(queue.entry(transactionId: "legacy")?.attempts, 999)
        XCTAssertEqual(storage.purchaseEnvironment("old-sandbox-proof"), .sandbox)
        let sent = transport.requests.count
        await engine.drainQueue()
        XCTAssertEqual(transport.requests.count, sent)
        box.value = .sandbox
        await engine.drainQueue()
        XCTAssertNil(queue.entry(transactionId: "legacy"))
    }
}
