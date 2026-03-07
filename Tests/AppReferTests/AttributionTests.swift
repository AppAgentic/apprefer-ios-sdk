import XCTest
@testable import AppRefer

final class AttributionTests: XCTestCase {

    func testDecodeFullAttribution() throws {
        let json = """
        {
            "network": "meta",
            "campaign": "summer_sale",
            "match_type": "click_id",
            "attribution_id": "attr_123",
            "campaign_id": "camp_456",
            "campaign_name": "Summer Sale 2024",
            "ad_group_id": "adg_789",
            "ad_id": "ad_012",
            "keyword": "fitness app",
            "fbclid": "fb_click_123",
            "gclid": null,
            "ttclid": null,
            "query_params": {"utm_source": "facebook"},
            "created_at": "2024-06-15T10:30:00Z"
        }
        """.data(using: .utf8)!

        let attribution = try JSONDecoder().decode(Attribution.self, from: json)

        XCTAssertEqual(attribution.network, "meta")
        XCTAssertEqual(attribution.campaign, "summer_sale")
        XCTAssertEqual(attribution.matchType, "click_id")
        XCTAssertEqual(attribution.attributionId, "attr_123")
        XCTAssertEqual(attribution.campaignId, "camp_456")
        XCTAssertEqual(attribution.campaignName, "Summer Sale 2024")
        XCTAssertEqual(attribution.adGroupId, "adg_789")
        XCTAssertEqual(attribution.adId, "ad_012")
        XCTAssertEqual(attribution.keyword, "fitness app")
        XCTAssertEqual(attribution.fbclid, "fb_click_123")
        XCTAssertNil(attribution.gclid)
        XCTAssertNil(attribution.ttclid)
        XCTAssertEqual(attribution.queryParams["utm_source"], "facebook")
    }

    func testDecodeMinimalAttribution() throws {
        let json = """
        {
            "network": "organic"
        }
        """.data(using: .utf8)!

        let attribution = try JSONDecoder().decode(Attribution.self, from: json)

        XCTAssertEqual(attribution.network, "organic")
        XCTAssertEqual(attribution.matchType, "organic") // default
        XCTAssertNil(attribution.campaign)
        XCTAssertNil(attribution.attributionId)
        XCTAssertTrue(attribution.queryParams.isEmpty)
    }

    func testDecodeEmptyJsonUsesDefaults() throws {
        let json = "{}".data(using: .utf8)!

        let attribution = try JSONDecoder().decode(Attribution.self, from: json)

        XCTAssertEqual(attribution.network, "unknown")
        XCTAssertEqual(attribution.matchType, "organic")
    }

    func testEncodeDecodeRoundtrip() throws {
        let json = """
        {
            "network": "google",
            "match_type": "click_id",
            "gclid": "gclid_abc",
            "query_params": {},
            "created_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let original = try JSONDecoder().decode(Attribution.self, from: json)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Attribution.self, from: encoded)

        XCTAssertEqual(original.network, decoded.network)
        XCTAssertEqual(original.matchType, decoded.matchType)
        XCTAssertEqual(original.gclid, decoded.gclid)
    }

    func testDecodeDateWithFractionalSeconds() throws {
        let json = """
        {
            "network": "meta",
            "created_at": "2024-06-15T10:30:00.123Z"
        }
        """.data(using: .utf8)!

        let attribution = try JSONDecoder().decode(Attribution.self, from: json)
        XCTAssertEqual(attribution.network, "meta")
        // Should parse without error
    }
}
