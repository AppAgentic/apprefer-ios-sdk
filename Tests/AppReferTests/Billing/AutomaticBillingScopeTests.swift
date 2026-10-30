import Foundation
import XCTest
@testable import AppRefer

final class AutomaticBillingScopeTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testExactProofRecoveryAcrossRestartWithoutRawKeyOnDisk() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_secret" }, explicit: nil)
        try scope.setUser("buyer")
        let ticket = try XCTUnwrap(scope.capture(user: "buyer"))
        XCTAssertNil(scope.recoverProof(user: "buyer", proof: "old queue"))
        try scope.authorizeProof("exact proof", ticket: ticket)
        let restarted = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_secret" }, explicit: nil)
        try restarted.setUser("buyer")
        let recovered = try XCTUnwrap(restarted.recoverProof(user: "buyer", proof: "exact proof"))
        XCTAssertNil(restarted.recoverProof(user: "buyer", proof: "different proof"))
        XCTAssertFalse(try restarted.commit(recovered, environment: .sandbox, owner: "other"))
        XCTAssertNil(restarted.environment(user: "buyer"))
        XCTAssertTrue(try restarted.commit(recovered, environment: .sandbox, owner: "buyer"))
        XCTAssertEqual(restarted.environment(user: "buyer"), .sandbox)
        let path = directory.appendingPathComponent("automatic-environments-v1.json")
        XCTAssertFalse(try String(contentsOf: path).contains("pk_live_secret"))
        XCTAssertEqual(try path.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testIdentityResetAndKeyPartitionsInvalidateCapabilities() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_a" }, explicit: nil)
        try scope.setUser("buyer")
        let ticket = try XCTUnwrap(scope.capture(user: "buyer"))
        try scope.authorizeProof("proof", ticket: ticket)
        XCTAssertTrue(try scope.commit(ticket, environment: .sandbox, owner: "buyer"))
        let otherKey = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_b" }, explicit: nil)
        XCTAssertNil(otherKey.environment(user: "buyer"))
        XCTAssertNil(otherKey.recoverProof(user: "buyer", proof: "proof"))
        try scope.setUser("buyer", invalidate: true)
        XCTAssertFalse(scope.isCurrent(ticket))
        XCTAssertNil(scope.recoverProof(user: "buyer", proof: "proof"))
        XCTAssertEqual(scope.environment(user: "buyer"), .sandbox)
        try scope.setUser("other")
        XCTAssertNil(scope.environment(user: "other"))
        try scope.setUser("buyer")
        XCTAssertNil(scope.recoverProof(user: "buyer", proof: "proof"))
    }

    func testExplicitAndTestKeysCannotCreateAutomaticAuthorization() throws {
        for (key, explicit) in [("pk_test_a", Optional<BillingEnvironment>.none), ("pk_live_a", .production), ("pk_live_a", .sandbox)] {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let scope = AutomaticBillingScope(directory: directory, apiKey: { key }, explicit: explicit)
            try scope.setUser("buyer")
            XCTAssertNil(scope.capture(user: "buyer"))
        }
    }

    func testCorruptAuthorizationDoesNotInventPermission() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("automatic-environments-v1.json"))
        let scope = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_a" }, explicit: nil)
        XCTAssertThrowsError(try scope.setUser("buyer"))
        XCTAssertNil(scope.capture(user: "buyer"))
        XCTAssertNil(scope.recoverProof(user: "buyer", proof: "anything"))
    }
    func testDefaultLivePurchaseWithMissingAppContextAdoptsOnlyOwnedSandboxAnswer() async throws {
        for owner in ["buyer", "wrong-owner"] {
            let env = BillingTestEnvironment()
            defer { env.cleanUp() }
            let automatic = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
            let scope: @Sendable () -> BillingEnvironment? = { automatic.select(base: .production, verifiedStoreEnvironment: nil) }
            let transport = MockBillingTransport { request in
                let selected = request.value(forHTTPHeaderField: "X-AppRefer-Billing-Environment")!
                let isPurchase = request.url!.path.hasSuffix("purchases")
                return (try JSONSerialization.data(withJSONObject: ["appUserId": isPurchase ? owner : "buyer", "environment": selected, "entitlements": [:], "activeSubscriptions": []]), 200)
            }
            let engine = env.engine(transport: transport, options: .init(environment: scope, automaticScope: automatic), appUserId: "buyer", apiKey: "pk_live_a")
            let intent = try await engine.beginPurchase(productId: "plan")
            let payload = Data(#"{"environment":"Sandbox"}"#.utf8).base64EncodedString()
            let transaction = StoreTransaction(id: "fresh", originalId: "fresh", productId: "plan", kind: .autoRenewable,
                purchaseDate: BillingFixtures.now, expirationDate: nil, revocationDate: nil, isUpgraded: false,
                periodType: .normal, signedTransaction: "a.\(payload).s")
            _ = await engine.process(StoreKitUpdate(verified: transaction, transactionId: transaction.id, finish: {}), initiator: "buyer", intent: intent)
            XCTAssertEqual(scope(), owner == "buyer" ? .sandbox : .production)
            let restarted = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
            XCTAssertEqual(restarted.select(base: .production, verifiedStoreEnvironment: nil), owner == "buyer" ? .sandbox : .production)
            // A new verified app context takes precedence over a prior install context.
            XCTAssertEqual(restarted.select(base: .production, verifiedStoreEnvironment: .production), .production)
        }
    }

    func testAuthorizedQueueRecoversButLegacyQueueCannotSwitchScope() async throws {
        let env = BillingTestEnvironment()
        defer { env.cleanUp() }
        let automatic = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
        try automatic.setUser("buyer")
        try automatic.authorizeProof("authorized", ticket: XCTUnwrap(automatic.capture(user: "buyer")))
        let queue = env.queue()
        for proof in ["legacy", "authorized"] {
            XCTAssertTrue(queue.add(PendingPurchase(transactionId: proof, productId: "plan", appUserId: "buyer", appreferId: nil, signedTransaction: proof, enqueuedAt: BillingFixtures.now, attempts: 0)))
        }
        let restarted = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
        let scope: @Sendable () -> BillingEnvironment? = { restarted.select(base: .production, verifiedStoreEnvironment: nil) }
        let transport = MockBillingTransport { request in
            let selected = request.value(forHTTPHeaderField: "X-AppRefer-Billing-Environment")!
            if request.url!.path.hasSuffix("purchases"), selected == "production" {
                return (Data(#"{"code":"billing_environment_mismatch","environment":"sandbox"}"#.utf8), 400)
            }
            return (try JSONSerialization.data(withJSONObject: ["appUserId": "buyer", "environment": selected, "entitlements": [:], "activeSubscriptions": []]), 200)
        }
        let engine = env.engine(transport: transport, options: .init(environment: scope, automaticScope: restarted), appUserId: "buyer", queue: queue, apiKey: "pk_live_a")
        await engine.drainQueue()
        XCTAssertEqual(scope(), .sandbox)
        XCTAssertNil(queue.entry(transactionId: "authorized"))
        XCTAssertNotNil(queue.entry(transactionId: "legacy"))
        XCTAssertNil(restarted.recoverProof(user: "buyer", proof: "legacy"))
    }

    func testOnlyDurableMatchingIntentCanAuthorizeVerifiedFreshTransaction() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_a" }, explicit: nil)
        try scope.setUser("buyer")
        let token = UUID()
        let intent = PurchaseIntent(appUserId: "buyer", productId: "plan", accountToken: token, startedAt: BillingFixtures.now)
        var transaction = StoreTransaction(id: "fresh", originalId: "fresh", productId: "plan", kind: .autoRenewable,
            purchaseDate: BillingFixtures.now, expirationDate: nil, revocationDate: nil, isUpgraded: false,
            periodType: .normal, signedTransaction: "proof", appAccountToken: token)
        XCTAssertNil(scope.recoverIntent(intent, verified: transaction))
        try scope.authorizeIntent(intent, ticket: XCTUnwrap(scope.capture(user: "buyer")))
        let restart = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_a" }, explicit: nil)
        XCTAssertNotNil(restart.recoverIntent(intent, verified: transaction))
        transaction.appAccountToken = UUID()
        XCTAssertNil(restart.recoverIntent(intent, verified: transaction))
        try restart.forgetIntent(intent.id)
        transaction.appAccountToken = token
        XCTAssertNil(restart.recoverIntent(intent, verified: transaction))
    }

    func testAnonymousInheritanceRequiresConfirmedTargetAndDoesNotCrossMemberSwitch() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_a" }, explicit: nil)
        let anonymous = "$ARAnon:123"
        XCTAssertTrue(BillingStorage.isAnonymous(anonymous))
        try scope.setUser(anonymous)
        XCTAssertTrue(try scope.commit(XCTUnwrap(scope.capture(user: anonymous)), environment: .sandbox, owner: anonymous))
        try scope.setUser("member")
        let member = try XCTUnwrap(scope.capture(user: "member"))
        try scope.inheritConfirmedAnonymous(anonymous, ticket: member, owner: "wrong")
        XCTAssertNil(scope.environment(user: "member"))
        try scope.inheritConfirmedAnonymous(anonymous, ticket: member, owner: "member")
        XCTAssertEqual(scope.environment(user: "member"), .sandbox)
        try scope.setUser("other")
        try scope.inheritConfirmedAnonymous("member", ticket: XCTUnwrap(scope.capture(user: "other")), owner: "other")
        XCTAssertNil(scope.environment(user: "other"))
    }

    func testUnreadableProtectedStateAndFailedWriteRecoverWithoutRestart() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("automatic-environments-v1.json")
        // A directory at the file path forces a transient read error rather than a
        // malformed authorization document. Replacing it models data becoming readable.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let scope = AutomaticBillingScope(directory: directory, apiKey: { "pk_live_a" }, explicit: nil)
        XCTAssertNil(scope.capture(user: "buyer"))
        try FileManager.default.removeItem(at: file)
        try scope.setUser("buyer")
        let ticket = try XCTUnwrap(scope.capture(user: "buyer"))
        let saved = directory.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: directory, to: saved)
        try Data().write(to: directory)
        XCTAssertThrowsError(try scope.authorizeProof("not-saved", ticket: ticket))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: saved, to: directory)
        try scope.setUser("buyer")
        XCTAssertNil(scope.recoverProof(user: "buyer", proof: "not-saved"))
        let recovered = try XCTUnwrap(scope.capture(user: "buyer"))
        try scope.authorizeProof("saved", ticket: recovered)
        XCTAssertNotNil(scope.recoverProof(user: "buyer", proof: "saved"))
    }

    func testResetBeforeConfigureRevokesPreviousLaunchProofEvenOnRepeatedSameUserReset() async throws {
        let env = BillingTestEnvironment()
        defer { env.cleanUp() }
        let storage = env.storage()
        storage.loggedInAppUserId = "buyer"
        for proof in ["previous-launch", "after-first-reset"] {
            let scope = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
            try scope.setUser("buyer", resetMarked: storage.resetMarkerHolds(for: "buyer"), resetGeneration: storage.automaticResetGeneration)
            try scope.authorizeProof(proof, ticket: XCTUnwrap(scope.capture(user: "buyer")))
            // This is the no-engine reset path used before Billing.configure.
            storage.recordAccountReset()
            let restart = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
            let selected: @Sendable () -> BillingEnvironment? = { restart.select(base: .production, verifiedStoreEnvironment: nil) }
            let engine = env.engine(transport: MockBillingTransport.unreachable(), options: .init(environment: selected, automaticScope: restart), appUserId: "buyer", storage: storage, apiKey: "pk_live_a")
            _ = await engine.localFallback()
            XCTAssertNil(restart.recoverProof(user: "buyer", proof: proof))
        }
    }

    func testFreshOutageQueuesAuthorizedProofAndRelaunchRecoversSandbox() async throws {
        let env = BillingTestEnvironment()
        defer { env.cleanUp() }
        let automatic = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
        let scope: @Sendable () -> BillingEnvironment? = { automatic.select(base: .production, verifiedStoreEnvironment: nil) }
        let queue = env.queue()
        let engine = env.engine(transport: MockBillingTransport.unreachable(), options: .init(environment: scope, automaticScope: automatic), appUserId: "buyer", queue: queue, apiKey: "pk_live_a")
        let intent = try await engine.beginPurchase(productId: "plan")
        let payload = Data(#"{"environment":"Sandbox"}"#.utf8).base64EncodedString()
        let transaction = StoreTransaction(id: "fresh", originalId: "fresh", productId: "plan", kind: .autoRenewable,
            purchaseDate: BillingFixtures.now, expirationDate: nil, revocationDate: nil, isUpgraded: false,
            periodType: .normal, signedTransaction: "a.\(payload).s")
        _ = await engine.process(StoreKitUpdate(verified: transaction, transactionId: transaction.id, finish: {}), initiator: "buyer", intent: intent)
        XCTAssertNotNil(queue.entry(transactionId: "fresh"))
        XCTAssertEqual(scope(), .production)
        let restarted = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
        let selected: @Sendable () -> BillingEnvironment? = { restarted.select(base: .production, verifiedStoreEnvironment: nil) }
        let transport = MockBillingTransport { request in
            let scope = request.value(forHTTPHeaderField: "X-AppRefer-Billing-Environment")!
            if request.url!.path.hasSuffix("purchases"), scope == "production" {
                return (Data(#"{"code":"billing_environment_mismatch","environment":"sandbox"}"#.utf8), 400)
            }
            return (try JSONSerialization.data(withJSONObject: ["appUserId": "buyer", "environment": scope, "entitlements": [:], "activeSubscriptions": []]), 200)
        }
        let recovered = env.engine(transport: transport, options: .init(environment: selected, automaticScope: restarted), appUserId: "buyer", queue: env.queue(), apiKey: "pk_live_a")
        await recovered.drainQueue()
        XCTAssertNil(env.queue().entry(transactionId: "fresh"))
        XCTAssertEqual(selected(), .sandbox)
    }

    func testFinishedAuthorizedProofRecoversOnStartAfterCrashBeforeContextCommit() async throws {
        let env = BillingTestEnvironment()
        defer { env.cleanUp() }
        let payload = Data(#"{"environment":"Sandbox"}"#.utf8).base64EncodedString()
        let transaction = StoreTransaction(id: "finished", originalId: "finished", productId: "plan", kind: .autoRenewable,
            purchaseDate: BillingFixtures.now, expirationDate: nil, revocationDate: nil, isUpgraded: false,
            periodType: .normal, signedTransaction: "a.\(payload).s")
        let old = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
        try old.setUser("buyer")
        try old.authorizeProof(transaction.signedTransaction, ticket: XCTUnwrap(old.capture(user: "buyer")))
        // Server has accepted this exact proof, StoreKit has no unfinished transaction,
        // and the process stopped before the owned context could be committed.
        let restarted = AutomaticBillingScope(directory: env.directory, apiKey: { "pk_live_a" }, explicit: nil)
        let selected: @Sendable () -> BillingEnvironment? = { restarted.select(base: .production, verifiedStoreEnvironment: nil) }
        let transport = MockBillingTransport { request in
            let scope = request.value(forHTTPHeaderField: "X-AppRefer-Billing-Environment")!
            return (try JSONSerialization.data(withJSONObject: ["appUserId": "buyer", "environment": scope, "entitlements": [:], "activeSubscriptions": []]), 200)
        }
        let store = FakeStoreKit(entitlements: [transaction])
        let engine = env.engine(transport: transport, storeKit: store, options: .init(environment: selected, automaticScope: restarted), appUserId: "buyer", apiKey: "pk_live_a")
        await engine.start()
        XCTAssertEqual(selected(), .sandbox)
        XCTAssertNil(restarted.recoverProof(user: "buyer", proof: transaction.signedTransaction))
        XCTAssertTrue(transport.requests(to: "/api/billing/v1/purchases").contains { $0.jsonBody?["signedTransaction"] as? String == transaction.signedTransaction })
    }

}
