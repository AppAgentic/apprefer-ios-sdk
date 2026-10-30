import Foundation
import XCTest
@testable import AppRefer

final class BillingEnvironmentTests: XCTestCase {
    func testDefaultsAndTestKeyRestriction() throws {
        XCTAssertEqual(try BillingEnvironment.select(apiKey: "pk_live_a"), .production)
        XCTAssertEqual(try BillingEnvironment.select(apiKey: "pk_test_a"), .sandbox)
        XCTAssertEqual(try BillingEnvironment.select(apiKey: "pk_live_a", explicit: .sandbox), .sandbox)
        XCTAssertThrowsError(try BillingEnvironment.select(apiKey: "pk_test_a", explicit: .production))
    }

    func testScopeSurvivesCacheAndReevaluation() throws {
        let data = Data(#"{"appUserId":"same-user","environment":"sandbox","entitlements":{},"activeSubscriptions":[],"requestDateMs":1}"#.utf8)
        let info = try JSONDecoder().decode(AppReferCustomerInfo.self, from: data)
        XCTAssertEqual(info.environment, .sandbox)
        XCTAssertEqual(info.reevaluated(at: Date()).environment, .sandbox)
        XCTAssertEqual(info.with(source: .cache).environment, .sandbox)
        XCTAssertEqual(try JSONDecoder().decode(AppReferCustomerInfo.self, from: JSONEncoder().encode(info)).environment, .sandbox)
        let old = Data(#"{"appUserId":"same-user"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AppReferCustomerInfo.self, from: old).environment)
    }

    func testScopedTransportRejectsUnscopedAndOtherEnvironmentAnswers() async throws {
        for selected in [BillingEnvironment.production, .sandbox] {
            for returned in [selected.rawValue, selected == .production ? "sandbox" : "production", ""] {
                let transport = MockBillingTransport { request in
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-AppRefer-Billing-Environment"), selected.rawValue)
                    return (try JSONSerialization.data(withJSONObject: ["appUserId": "same-user", "environment": returned]), 200)
                }
                let api = BillingAPIClient(baseURLs: ["https://example.com"], apiKey: { "pk_live_a" }, transport: transport, environment: selected)
                do {
                    let response = try await api.send(.getCustomer(appUserId: "same-user"))
                    XCTAssertEqual(returned, selected.rawValue)
                    XCTAssertEqual(response.info.environment, selected)
                } catch {
                    XCTAssertNotEqual(returned, selected.rawValue)
                }
            }
        }
    }
}
