import XCTest
import CryptoKit
@testable import AppRefer

final class BillingLegacyAccountTokenTests: XCTestCase {
    func testLegacyUUIDUnlocksOnlineAndImportsWithoutRestoreForBothUUIDCases() async throws {
        for user in ["6F9619FF-8B86-D011-B42D-00C04FC964FF", "6f9619ff-8b86-d011-b42d-00c04fc964ff"] {
            let env = BillingTestEnvironment()
            let storage = env.storage()
            storage.setAccountToken(BillingFixtures.otherAccountToken.uuidString, for: user)
            // A 0.13.1 launch already marked migration complete while skipping this token.
            let key = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
            try Data("done".utf8).write(to: env.directory.appendingPathComponent("migration-\(key).flag"))
            XCTAssertFalse(storage.migrationSynced(user))
            let store = FakeStoreKit(entitlements: [BillingFixtures.transaction(appAccountToken: UUID(uuidString: user))])
            let transport = MockBillingTransport { _ in
                var body = try JSONSerialization.jsonObject(with: Data(BillingFixtures.emptyCustomerJSON(appUserId: user).utf8)) as! [String: Any]
                body["accountToken"] = BillingFixtures.otherAccountToken.uuidString
                body["legacyAppAccountToken"] = user.lowercased()
                return (try JSONSerialization.data(withJSONObject: body), 200)
            }
            let engine = env.engine(transport: transport, storeKit: store, appUserId: user, storage: storage)
            let online = await engine.customerInfo(policy: .fetchCurrent)
            XCTAssertEqual(online.entitlements["premium"]?.isActive, true)
            await engine.migrationSync()
            await engine.migrationSync()
            let requests = transport.requests(to: "/api/billing/v1/purchases")
            XCTAssertEqual(requests.count, 1)
            guard let request = requests.first else { XCTFail("Legacy import missing"); continue }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["appUserId"] as? String, user)
            XCTAssertNil(body["restore"])
            XCTAssertEqual(store.syncCalls, 0)
            XCTAssertTrue(storage.migrationSynced(user))
            env.cleanUp()
        }
    }

    func testCaseVariantCannotUseAnotherUsersConfirmedLegacyBinding() async throws {
        let upper = "6F9619FF-8B86-D011-B42D-00C04FC964FF", lower = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
        let env = BillingTestEnvironment()
        let store = FakeStoreKit(entitlements: [BillingFixtures.transaction(appAccountToken: UUID(uuidString: upper))])
        let transport = MockBillingTransport { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let user = body?["appUserId"] as? String ?? query?.first(where: { $0.name == "appUserId" })?.value ?? upper
            var answer = try JSONSerialization.jsonObject(with: Data(BillingFixtures.emptyCustomerJSON(appUserId: user).utf8)) as! [String: Any]
            answer["accountToken"] = user == upper ? BillingFixtures.otherAccountToken.uuidString : "22222222-3333-4444-5555-666666666666"
            if user == upper { answer["legacyAppAccountToken"] = lower }
            return (try JSONSerialization.data(withJSONObject: answer), 200)
        }
        let engine = env.engine(transport: transport, storeKit: store, appUserId: upper)
        let first = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(first.entitlements["premium"]?.isActive, true)
        _ = try await engine.logIn(lower)
        let switched = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertNotEqual(switched.entitlements["premium"]?.isActive, true)
        _ = await engine.process(BillingFixtures.update(store.entitlements[0], counter: FinishCounter()))
        await engine.migrationSync()
        for request in transport.requests(to: "/api/billing/v1/purchases") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertNotEqual(body["appUserId"] as? String, lower)
        }
        env.cleanUp()
    }

    func testKnownForeignTokenWinsEvenWhenItEqualsLegacyUserUUID() async {
        let env = BillingTestEnvironment()
        let user = BillingFixtures.accountToken.uuidString
        let storage = env.storage()
        storage.setAccountToken(user, for: "other")
        let store = FakeStoreKit(entitlements: [BillingFixtures.transaction(appAccountToken: BillingFixtures.accountToken)])
        let transport = MockBillingTransport.ok(BillingFixtures.emptyCustomerJSON(appUserId: user).replacingOccurrences(of: BillingFixtures.accountToken.uuidString, with: BillingFixtures.otherAccountToken.uuidString))
        let engine = env.engine(transport: transport, storeKit: store, appUserId: user, storage: storage)
        let online = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertNotEqual(online.entitlements["premium"]?.isActive, true)
        await engine.migrationSync()
        XCTAssertTrue(transport.requests(to: "/api/billing/v1/purchases").isEmpty)
        env.cleanUp()
    }
    func testPermanentOwnershipConflictDoesNotGrantOrBlockNextPurchase() async {
        let user = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
        let env = BillingTestEnvironment()
        let transaction = BillingFixtures.transaction(appAccountToken: UUID(uuidString: user))
        let store = FakeStoreKit(entitlements: [transaction])
        let transport = MockBillingTransport { request in
            if request.url!.path.hasSuffix("/purchases"), !(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "").contains("valid-next") { return (Data("{}".utf8), 422) }
            let body = BillingFixtures.emptyCustomerJSON(appUserId: user).replacingOccurrences(of: BillingFixtures.accountToken.uuidString, with: BillingFixtures.otherAccountToken.uuidString)
            return (Data(body.utf8), 200)
        }
        let queue = env.queue()
        let engine = env.engine(transport: transport, storeKit: store, appUserId: user, queue: queue)
        let result = await engine.process(BillingFixtures.update(transaction, counter: FinishCounter()))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNotEqual(result.entitlements["premium"]?.isActive, true)
        let online = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertNotEqual(online.entitlements["premium"]?.isActive, true)
        let valid = BillingFixtures.transaction(id: "valid-next", appAccountToken: BillingFixtures.otherAccountToken)
        store.entitlements.append(valid)
        let next = await engine.process(BillingFixtures.update(valid, counter: FinishCounter()))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(next.entitlements["premium"]?.isActive, true)
        env.cleanUp()
    }

}
