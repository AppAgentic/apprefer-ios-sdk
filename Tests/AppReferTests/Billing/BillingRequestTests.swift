import XCTest
@testable import AppRefer

final class BillingRequestTests: XCTestCase {
    private let base = "https://trk.apprefer.com"

    func testCreateCustomerRequest() throws {
        let request = try BillingAPIClient.makeRequest(
            .createCustomer(appUserId: "user_1", appreferId: "device-abc", attributes: ["$email": "a@example.com"]),
            baseURL: base, apiKey: "pk_live_1"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://trk.apprefer.com/api/billing/v1/customers")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AppRefer-Key"), "pk_live_1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SDK-Version"), AppReferVersion.current)
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["appUserId"] as? String, "user_1")
        XCTAssertEqual(body["appreferId"] as? String, "device-abc")
        XCTAssertEqual(body["attributes"] as? [String: String], ["$email": "a@example.com"])
    }

    func testCreateCustomerOmitsEmptyOptionalFields() throws {
        let request = try BillingAPIClient.makeRequest(
            .createCustomer(appUserId: "u", appreferId: nil, attributes: [:]), baseURL: base, apiKey: "k"
        )
        XCTAssertEqual(try XCTUnwrap(request.jsonBody).keys.sorted(), ["appUserId"])
    }

    func testGetCustomerEncodesAnonymousIdAndPlus() throws {
        let anon = try BillingAPIClient.makeRequest(
            .getCustomer(appUserId: "$ARAnon:6F9619FF-8B86-D011-B42D-00C04FC964FF"), baseURL: base, apiKey: "k"
        )
        XCTAssertEqual(anon.httpMethod, "GET")
        XCTAssertNil(anon.httpBody)
        let components = try XCTUnwrap(anon.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.path, "/api/billing/v1/customers")
        XCTAssertEqual(components.queryItems?.first?.value, "$ARAnon:6F9619FF-8B86-D011-B42D-00C04FC964FF")

        let plus = try BillingAPIClient.makeRequest(.getCustomer(appUserId: "a+b@x.com"), baseURL: base, apiKey: "k")
        XCTAssertEqual(plus.url?.query, "appUserId=a%2Bb@x.com")
    }

    func testPurchaseRequest() throws {
        let request = try BillingAPIClient.makeRequest(
            .purchase(appUserId: "u", appreferId: "d", signedTransaction: "eyJ.jws.sig", attributes: [:]),
            baseURL: base, apiKey: "k"
        )
        XCTAssertEqual(request.url?.path, "/api/billing/v1/purchases")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["store"] as? String, "app_store")
        XCTAssertEqual(body["signedTransaction"] as? String, "eyJ.jws.sig")
        XCTAssertEqual(body["appUserId"] as? String, "u")
        XCTAssertEqual(body["appreferId"] as? String, "d")
        XCTAssertNil(body["attributes"])
    }

    func testIdentifyRequest() throws {
        let request = try BillingAPIClient.makeRequest(
            .identify(anonymousId: "$ARAnon:6F9619FF-8B86-D011-B42D-00C04FC964FF", appUserId: "user_1"),
            baseURL: base, apiKey: "k"
        )
        XCTAssertEqual(request.url?.path, "/api/billing/v1/identify")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["anonymousId"] as? String, "$ARAnon:6F9619FF-8B86-D011-B42D-00C04FC964FF")
        XCTAssertEqual(body["appUserId"] as? String, "user_1")
    }

    // MARK: - Failover

    private func client(_ transport: MockBillingTransport, key: String? = "pk") -> BillingAPIClient {
        BillingAPIClient(
            baseURLs: ["https://trk.apprefer.com", "https://apprefer.com"],
            apiKey: { key }, transport: transport, keyWaitAttempts: 0
        )
    }

    func testFallsBackToMainHostWhenTrackingHostIsDown() async throws {
        let transport = MockBillingTransport { request in
            if request.url?.host == "trk.apprefer.com" { throw AppReferBillingError.network("down") }
            return (Data(BillingFixtures.customerJSON(appUserId: "u").utf8), 200)
        }
        let response = try await client(transport).send(.getCustomer(appUserId: "u"))
        XCTAssertEqual(response.info.appUserId, "u")
        XCTAssertEqual(transport.requests.map { $0.url?.host }, ["trk.apprefer.com", "apprefer.com"])
    }

    func testFallsBackOn5xx() async throws {
        let transport = MockBillingTransport { request in
            if request.url?.host == "trk.apprefer.com" { return (Data(#"{"error":"boom"}"#.utf8), 502) }
            return (Data(BillingFixtures.customerJSON(appUserId: "u").utf8), 200)
        }
        _ = try await client(transport).send(.getCustomer(appUserId: "u"))
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testClientErrorIsFinalAndNotRetried() async {
        let transport = MockBillingTransport { _ in (Data(#"{"error":"Invalid transaction (bad_chain)"}"#.utf8), 400) }
        do {
            _ = try await client(transport).send(.getCustomer(appUserId: "u"))
            XCTFail("expected error")
        } catch let error as AppReferBillingError {
            XCTAssertEqual(error, .server(status: 400, message: "Invalid transaction (bad_chain)"))
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testAllHostsDownThrowsRetryableError() async {
        let transport = MockBillingTransport.unreachable()
        do {
            _ = try await client(transport).send(.getCustomer(appUserId: "u"))
            XCTFail("expected error")
        } catch let error as AppReferBillingError {
            XCTAssertTrue(error.isRetryable)
            XCTAssertTrue(error.isConnectivity)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMissingApiKeyMakesNoRequest() async {
        let transport = MockBillingTransport.ok("{}")
        do {
            _ = try await client(transport, key: nil).send(.getCustomer(appUserId: "u"))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AppReferBillingError, .missingApiKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testWaitsBrieflyForApiKeyFromAppReferConfigure() async throws {
        final class KeyBox: @unchecked Sendable { var calls = 0 }
        let box = KeyBox()
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "u"))
        let client = BillingAPIClient(
            baseURLs: ["https://trk.apprefer.com"],
            apiKey: { box.calls += 1; return box.calls >= 3 ? "pk_late" : nil },
            transport: transport, keyWaitAttempts: 5
        )
        _ = try await client.send(.getCustomer(appUserId: "u"))
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "X-AppRefer-Key"), "pk_late")
    }

    func testRetryableClassification() {
        XCTAssertTrue(AppReferBillingError.server(status: 404, message: "Billing not enabled for this app").isRetryable)
        XCTAssertTrue(AppReferBillingError.server(status: 409, message: nil).isRetryable)
        XCTAssertTrue(AppReferBillingError.server(status: 429, message: nil).isRetryable)
        XCTAssertFalse(AppReferBillingError.server(status: 400, message: nil).isRetryable)
        XCTAssertFalse(AppReferBillingError.unverifiedTransaction.isRetryable)
    }
}
