import XCTest
@testable import AppRefer

final class HTTPClientTests: XCTestCase {

    func testInvalidURL_returnsNil() async {
        let logger = AppReferLogger(debug: false, logLevel: 0)
        let client = AppReferHTTPClient(
            backendURL: "not a url with spaces",
            apiKey: "pk_test",
            logger: logger
        )

        let result = await client.post("/api/track/configure", body: ["device_id": "test"])
        XCTAssertNil(result)
    }

    func testUnreachableHost_returnsNil() async {
        let logger = AppReferLogger(debug: true, logLevel: 3)
        let client = AppReferHTTPClient(
            backendURL: "http://192.0.2.1", // TEST-NET — guaranteed unreachable
            apiKey: "pk_test",
            logger: logger
        )

        // This will timeout/fail after retries
        let result = await client.post("/api/track/configure", body: ["device_id": "test"])
        XCTAssertNil(result)
    }
}
