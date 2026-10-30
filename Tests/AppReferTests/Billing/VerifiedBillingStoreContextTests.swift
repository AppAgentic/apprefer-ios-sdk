import Foundation
import XCTest
@testable import AppRefer

final class VerifiedBillingStoreContextTests: XCTestCase {
    func testOnlyKnownVerifiedContextIsReturned() async {
        for value in ["production", "sandbox", "unknown", ""] {
            let result = await VerifiedBillingStoreContext.environment { value }
            XCTAssertEqual(result, ["production", "sandbox"].contains(value) ? value : nil)
        }
    }
    func testUnavailableOrStalledLookupDoesNotSelectSandboxOrBlockConfigure() async {
        let missing = await VerifiedBillingStoreContext.environment { nil }
        XCTAssertNil(missing)
        let started = Date()
        let result = await VerifiedBillingStoreContext.environment(timeoutNanoseconds: 10_000_000) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return "sandbox"
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}
