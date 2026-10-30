import Foundation
import XCTest
@testable import AppRefer

private final class AutomaticRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var key = "pk_live_a"
    private var epoch = 0
    func currentKey() -> String { lock.lock(); defer { lock.unlock() }; return key }
    func currentEpoch() -> Int { lock.lock(); defer { lock.unlock() }; return epoch }
    func changeKey() { lock.lock(); key = "pk_live_b"; lock.unlock() }
    func reset() { lock.lock(); epoch += 1; lock.unlock() }
}

private actor AutomaticPurchaseGate: BillingTransport {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func waitForPurchase() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func send(_ request: URLRequest) async throws -> BillingHTTPResponse {
        if request.url!.path.hasSuffix("purchases"), !entered {
            entered = true
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                enteredWaiter?.resume(); enteredWaiter = nil
            }
        }
        let owner = request.jsonBody?["appUserId"] as? String ?? "buyer"
        let scope = request.value(forHTTPHeaderField: "X-AppRefer-Billing-Environment")!
        return BillingHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["appUserId": owner, "environment": scope, "entitlements": [:], "activeSubscriptions": []]), status: 200)
    }
}

final class AutomaticBillingRaceTests: XCTestCase {
    func testInFlightPurchaseCannotCommitAfterIdentityKeyOrResetChange() async throws {
        for change in ["identity", "key", "reset"] {
            let env = BillingTestEnvironment()
            defer { env.cleanUp() }
            let state = AutomaticRaceState()
            let automatic = AutomaticBillingScope(directory: env.directory, apiKey: { state.currentKey() }, explicit: nil, resetEpoch: { state.currentEpoch() })
            let selected: @Sendable () -> BillingEnvironment? = { automatic.select(base: .production, verifiedStoreEnvironment: nil) }
            let transport = AutomaticPurchaseGate()
            let engine = BillingEngine(api: BillingAPIClient(baseURLs: ["https://example.com"], apiKey: { state.currentKey() }, transport: transport, keyWaitAttempts: 0, environmentProvider: selected),
                storage: env.storage(), queue: env.queue(), storeKit: FakeStoreKit(), options: .init(environment: selected, automaticScope: automatic), appUserId: "buyer", appreferId: { nil }, accountEpoch: { state.currentEpoch() }, logger: AppReferLogger(debug: false, logLevel: 0), now: { BillingFixtures.now })
            let intent = try await engine.beginPurchase(productId: "plan")
            let payload = Data(#"{"environment":"Sandbox"}"#.utf8).base64EncodedString()
            let transaction = StoreTransaction(id: "fresh", originalId: "fresh", productId: "plan", kind: .autoRenewable,
                purchaseDate: BillingFixtures.now, expirationDate: nil, revocationDate: nil, isUpgraded: false,
                periodType: .normal, signedTransaction: "a.\(payload).s")
            let task = Task { await engine.process(StoreKitUpdate(verified: transaction, transactionId: transaction.id, finish: {}), initiator: "buyer", intent: intent) }
            await transport.waitForPurchase()
            switch change {
            case "identity": _ = try await engine.logIn("next-buyer")
            case "key": state.changeKey()
            default: state.reset()
            }
            await transport.release()
            _ = await task.value
            XCTAssertEqual(selected(), .production, change)
            XCTAssertNil(automatic.environment(user: "buyer"), change)
        }
    }
}
