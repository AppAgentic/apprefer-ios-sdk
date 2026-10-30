import XCTest
@testable import AppRefer

final class ResolvedBillingStoreContextTests: XCTestCase {
    func testTestKeyToLiveKeyKeepsVerifiedContext() async {
        let context = ResolvedBillingStoreContext()
        let store = FakeStoreKit()
        store.storeEnvironmentResult = .sandbox
        XCTAssertEqual(context.select(apiKey: "pk_test_a", explicit: nil), .sandbox)
        await context.resolve(from: store, explicit: nil)
        XCTAssertEqual(store.storeEnvironmentQueries, 1)
        XCTAssertEqual(context.select(apiKey: "pk_live_a", explicit: nil), .sandbox)
    }
    func testNoDefaultGrantWhileStoreContextIsPending() {
        let context = ResolvedBillingStoreContext()
        XCTAssertNil(context.select(apiKey: "pk_live_a", explicit: nil))
        XCTAssertNil(context.select(apiKey: nil, explicit: nil))
        context.resolve(.sandbox)
        XCTAssertEqual(context.select(apiKey: "pk_live_a", explicit: nil), .sandbox)
    }
    func testExplicitScopesAndTestKeysRemainStrict() {
        let context = ResolvedBillingStoreContext()
        context.resolve(.sandbox)
        XCTAssertEqual(context.select(apiKey: "pk_live_a", explicit: .production), .production)
        XCTAssertNil(context.select(apiKey: "pk_test_a", explicit: .production))
        context.resolve(.production)
        XCTAssertEqual(context.select(apiKey: "pk_test_a", explicit: nil), .sandbox)
    }
    func testUnknownContextDoesNotInventSandbox() {
        let context = ResolvedBillingStoreContext()
        context.resolve(nil)
        XCTAssertEqual(context.select(apiKey: "pk_live_a", explicit: nil), .production)
    }
}
