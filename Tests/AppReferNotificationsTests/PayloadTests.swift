import XCTest
@testable import AppReferNotifications

/// Wire schema 1 parsing: strict, never executes anything, and leaves non-AppRefer and
/// Support payloads alone.
final class PayloadTests: XCTestCase {
    static let installId = "ei_" + String(repeating: "a", count: 26)
    static let token = "er1." + String(repeating: "A", count: 43)

    static func object(_ overrides: [String: Any?] = [:]) -> [String: Any] {
        var o: [String: Any] = [
            "type": "engagement", "v": 1, "mid": "sparkly_live_finish-setup_abc_nudge", "purpose": "reminders",
            "exp": (Date().timeIntervalSince1970 + 3600) * 1000, "epoch": 2, "iid": installId, "dest": "/setup", "ck": "setup",
            "locale": "en-GB", "title": "Finish Garden", "body": "One step left.", "img": "https://assets.example.com/push/v1/a.png",
            "actions": [["id": "start", "kind": "start", "dest": "/setup/next"], ["id": "later", "kind": "snooze", "min": 60]],
            "rt": token,
        ]
        for (k, v) in overrides { if let v { o[k] = v } else { o.removeValue(forKey: k) } }
        return o
    }

    private func parse(_ overrides: [String: Any?]) -> AppReferEngagementPayload.Result {
        AppReferEngagementPayload.parse(userInfo: ["apprefer": Self.object(overrides)])
    }

    func testValidPayloadIsTypedAndCarriesItsCategory() throws {
        guard case .valid(let p) = parse([:]) else { return XCTFail("expected valid") }
        XCTAssertEqual(p.purpose, .reminders)
        XCTAssertEqual(p.accountEpoch, 2)
        XCTAssertEqual(p.installId, Self.installId)
        XCTAssertEqual(p.destination, "/setup")
        XCTAssertEqual(p.imageURL?.absoluteString, "https://assets.example.com/push/v1/a.png")
        XCTAssertEqual(p.actions.map(\.kind), [.start, .snooze])
        XCTAssertEqual(p.actions[1].snoozeMinutes, 60)
        XCTAssertEqual(p.categoryIdentifier, "apprefer.eng.start.snooze")
        XCTAssertFalse(p.isExpired())
    }

    func testOtherNotificationsAreNotClaimed() {
        XCTAssertEqual(AppReferEngagementPayload.parse(userInfo: ["apprefer": ["type": "support_reply", "conversationId": "cv_1"]]), .notEngagement)
        XCTAssertEqual(AppReferEngagementPayload.parse(userInfo: ["aps": ["alert": "hi"]]), .notEngagement)
        XCTAssertEqual(AppReferEngagementPayload.parse(data: ["type": "support_reply", "conversationId": "cv_1"]), .notEngagement)
        XCTAssertEqual(AppReferEngagementPayload.parse(data: [:]), .notEngagement)
    }

    func testFcmDataMap() throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: Self.object()), encoding: .utf8)!
        let result = AppReferEngagementPayload.parse(data: ["type": "engagement", "v": "1", "engagement": json])
        guard case .valid = result else { return XCTFail("\(result)") }
        XCTAssertEqual(AppReferEngagementPayload.parse(data: ["type": "engagement", "engagement": "{not json"]), .invalid("malformed"))
        XCTAssertEqual(AppReferEngagementPayload.parse(data: ["type": "engagement", "engagement": String(repeating: "x", count: 9000)]), .invalid("malformed"))
    }

    func testUnsupportedSchemaAndMalformedFieldsAreRejected() {
        XCTAssertEqual(parse(["v": 2]), .invalid("unsupported_version"))
        XCTAssertEqual(parse(["v": true]), .invalid("unsupported_version"))
        XCTAssertEqual(parse(["mid": "a/b"]), .invalid("message_id"))
        XCTAssertEqual(parse(["purpose": "promo"]), .invalid("purpose"))
        XCTAssertEqual(parse(["exp": nil]), .invalid("expiry"))
        XCTAssertEqual(parse(["epoch": -1]), .invalid("epoch"))
        XCTAssertEqual(parse(["epoch": 1.5]), .invalid("epoch"))
        XCTAssertEqual(parse(["iid": "ei_short"]), .invalid("install"))
        XCTAssertEqual(parse(["title": String(repeating: "t", count: 129)]), .invalid("copy"))
        XCTAssertEqual(parse(["body": ""]), .invalid("copy"))
        XCTAssertEqual(parse(["rt": "token"]), .invalid("receipt_token"))
        XCTAssertEqual(parse(["ck": "Bad Key"]), .invalid("collapse_key"))
    }

    func testDestinationsAreInAppPathsOnly() {
        for bad in ["https://evil.example/x", "//evil.example/x", "javascript:alert(1)", "setup", "/a b", "/x#y", String(repeating: "/a", count: 200)] {
            XCTAssertEqual(parse(["dest": bad]), .invalid("destination"), bad)
            XCTAssertEqual(parse(["actions": [["id": "go", "kind": "open", "dest": bad]]]), .invalid("actions"), bad)
        }
        guard case .valid(let p) = parse(["dest": NSNull()]) else { return XCTFail() }
        XCTAssertNil(p.destination)
    }

    func testActionsAreBoundedAndTyped() {
        XCTAssertEqual(parse(["actions": [["id": "a", "kind": "open"], ["id": "b", "kind": "view"], ["id": "c", "kind": "start"]]]), .invalid("actions"))
        XCTAssertEqual(parse(["actions": [["id": "a", "kind": "open"], ["id": "b", "kind": "open"]]]), .invalid("actions"))
        XCTAssertEqual(parse(["actions": [["id": "a", "kind": "open"], ["id": "a", "kind": "view"]]]), .invalid("actions"))
        XCTAssertEqual(parse(["actions": [["id": "a", "kind": "share"]]]), .invalid("actions"))
        XCTAssertEqual(parse(["actions": [["id": "a", "kind": "snooze"]]]), .invalid("actions"))
        XCTAssertEqual(parse(["actions": [["id": "a", "kind": "snooze", "min": 2]]]), .invalid("actions"))
        XCTAssertEqual(parse(["actions": [["id": "a", "kind": "snooze", "min": 30, "dest": "/x"]]]), .invalid("actions"))
        XCTAssertEqual(parse(["actions": [["id": "Bad!", "kind": "open"]]]), .invalid("actions"))
        guard case .valid(let p) = parse(["actions": nil]) else { return XCTFail() }
        XCTAssertNil(p.categoryIdentifier)
    }

    func testImagePolicy() {
        for bad in ["http://assets.example.com/a.png", "https://assets.example.com:8443/a.png", "https://u:p@assets.example.com/a.png",
                    "https://10.0.0.1/a.png", "https://[::1]/a.png", "https://localhost/a.png", "https://assets.example.com/a.png?x=1",
                    "https://assets.example.com/a.png#f", "https://assets.example.com/a.gif", "https://assets.example.com/../a.png",
                    "https://assets.example.com//a.png", "https://assets.example.com/%2e%2e/a.png", "https://Assets.example.com/a.png",
                    "file:///etc/a.png", "https://assets.example.com/" + String(repeating: "a", count: 520) + ".png"] {
            XCTAssertNil(AppReferImagePolicy.validatedURL(bad), bad)
            XCTAssertEqual(parse(["img": bad]), .invalid("image"), bad)
        }
        let url = URL(string: "https://assets.example.com/push/a.jpg")!
        XCTAssertTrue(AppReferImagePolicy.isAllowed(url, allowedHosts: ["assets.example.com"]))
        XCTAssertFalse(AppReferImagePolicy.isAllowed(url, allowedHosts: ["example.com"]), "exact host names only")
        XCTAssertFalse(AppReferImagePolicy.isAllowed(url, allowedHosts: []))
    }

    func testExpiry() {
        guard case .valid(let p) = parse(["exp": (Date().timeIntervalSince1970 - 1) * 1000]) else { return XCTFail() }
        XCTAssertTrue(p.isExpired())
    }
}
