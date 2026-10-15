import XCTest
@testable import AppRefer

final class CustomerInfoDecodingTests: XCTestCase {
    /// Exactly what `POST /api/billing/v1/purchases` returns (CustomerInfo + accountToken + purchase).
    private let serverJSON = """
    {
      "appUserId": "user_42",
      "entitlements": {
        "premium": {
          "id": "premium", "isActive": true, "productId": "pro_yearly", "store": "app_store",
          "expiresAtMs": 1800086400000, "willRenew": true, "periodType": "trial",
          "state": "active", "subscriptionKey": "2000000000000001"
        },
        "lifetime": {
          "id": "lifetime", "isActive": true, "productId": "pro_lifetime", "store": "app_store",
          "expiresAtMs": null, "willRenew": false, "periodType": "normal",
          "state": "active", "subscriptionKey": "2000000000000009"
        },
        "coach": {
          "id": "coach", "isActive": false, "productId": "coach_monthly", "store": "play_store",
          "expiresAtMs": 1700000000000, "willRenew": false, "periodType": "normal",
          "state": "in_billing_retry", "subscriptionKey": "abc"
        }
      },
      "activeSubscriptions": ["pro_yearly"],
      "requestDateMs": 1800000000000,
      "accountToken": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "purchase": { "productId": "pro_yearly", "state": "active", "acknowledged": false, "conversion": "forwarded" }
    }
    """

    func testDecodesServerResponse() throws {
        let response = try JSONDecoder().decode(BillingCustomerResponse.self, from: Data(serverJSON.utf8))
        let info = response.info

        XCTAssertEqual(response.accountToken, "6F9619FF-8B86-D011-B42D-00C04FC964FF")
        XCTAssertEqual(info.appUserId, "user_42")
        XCTAssertEqual(info.source, .server)
        XCTAssertEqual(info.activeSubscriptions, ["pro_yearly"])
        XCTAssertEqual(info.requestDate, Date(timeIntervalSince1970: 1_800_000_000))

        let premium = try XCTUnwrap(info.entitlements["premium"])
        XCTAssertTrue(premium.isActive)
        XCTAssertEqual(premium.identifier, "premium")
        XCTAssertEqual(premium.productIdentifier, "pro_yearly")
        XCTAssertEqual(premium.store, .appStore)
        XCTAssertEqual(premium.expirationDate, Date(timeIntervalSince1970: 1_800_086_400))
        XCTAssertTrue(premium.willRenew)
        XCTAssertEqual(premium.periodType, .trial)
        XCTAssertEqual(premium.state, .active)

        XCTAssertNil(info.entitlements["lifetime"]?.expirationDate)
        XCTAssertEqual(info.entitlements["coach"]?.state, .inBillingRetry)
        XCTAssertEqual(info.entitlements["coach"]?.store, .playStore)
        XCTAssertEqual(Set(info.entitlements.active.keys), ["premium", "lifetime"])
        XCTAssertTrue(info.hasActiveEntitlement)
        XCTAssertNil(info.entitlements["missing"])
    }

    func testUnknownEnumValuesAndMissingIdDoNotFail() throws {
        let json = """
        {"appUserId":"u","entitlements":{"premium":{"isActive":true,"productId":"p","store":"web_store",
        "periodType":"future_thing","state":"brand_new_state"}},"activeSubscriptions":[],"requestDateMs":1}
        """
        let info = try JSONDecoder().decode(AppReferCustomerInfo.self, from: Data(json.utf8))
        let premium = try XCTUnwrap(info.entitlements["premium"])
        XCTAssertEqual(premium.identifier, "premium", "id falls back to the dictionary key")
        XCTAssertEqual(premium.store, .unknown)
        XCTAssertEqual(premium.periodType, .unknown)
        XCTAssertEqual(premium.state, .unknown)
        XCTAssertTrue(premium.isActive)
    }

    func testEncodeDecodeRoundTripKeepsSource() throws {
        let response = try JSONDecoder().decode(BillingCustomerResponse.self, from: Data(serverJSON.utf8))
        let cached = response.info.with(source: .localFallback)
        let decoded = try JSONDecoder().decode(AppReferCustomerInfo.self, from: JSONEncoder().encode(cached))
        XCTAssertEqual(decoded, cached)
    }

    func testReevaluatedExpiresStaleCacheButKeepsGracePeriod() throws {
        let json = """
        {"appUserId":"u","entitlements":{
          "premium":{"id":"premium","isActive":true,"productId":"m","store":"app_store","expiresAtMs":1000,"willRenew":true,"periodType":"normal","state":"active","subscriptionKey":"k"},
          "grace":{"id":"grace","isActive":true,"productId":"g","store":"app_store","expiresAtMs":1000,"willRenew":true,"periodType":"normal","state":"in_grace_period","subscriptionKey":"k2"},
          "life":{"id":"life","isActive":true,"productId":"l","store":"app_store","expiresAtMs":null,"willRenew":false,"periodType":"normal","state":"active","subscriptionKey":"k3"}
        },"activeSubscriptions":["m","g"],"requestDateMs":500}
        """
        let info = try JSONDecoder().decode(AppReferCustomerInfo.self, from: Data(json.utf8))
        let later = info.reevaluated(at: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(later.source, .cache)
        XCTAssertEqual(later.entitlements["premium"]?.isActive, false)
        XCTAssertEqual(later.entitlements["premium"]?.state, .expired)
        XCTAssertEqual(later.entitlements["grace"]?.isActive, true)
        XCTAssertEqual(later.entitlements["life"]?.isActive, true)
        XCTAssertEqual(later.activeSubscriptions, ["g"])
    }

    func testPublicTypealiasesResolveToSameTypes() {
        let info: CustomerInfo? = nil
        let prefixed: AppReferCustomerInfo? = info
        XCTAssertNil(prefixed)
        if #available(iOS 15.0, macOS 12.0, *) {
            let nested: AppReferBilling.CustomerInfo? = prefixed
            XCTAssertNil(nested)
        }
    }
}
