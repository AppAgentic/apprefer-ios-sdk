import XCTest
@testable import AppRefer

private final class FakeStatus: TrackingStatusProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppReferTrackingConsent
    init(_ value: AppReferTrackingConsent) { self.value = value }
    func set(_ v: AppReferTrackingConsent) { lock.lock(); value = v; lock.unlock() }
    func current() -> AppReferTrackingConsent { lock.lock(); defer { lock.unlock() }; return value }
}

private final class RecordingPoster: AppReferPosting, @unchecked Sendable {
    struct Call { let path: String; let body: [String: Any] }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var response: [String: Any]? = ["sdkEnabled": true, "attribution": ["network": "organic", "matchType": "organic"]]
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? {
        lock.lock(); calls.append(Call(path: path, body: body)); let r = response; lock.unlock()
        return r
    }
}

final class TrackingConsentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var status: FakeStatus!
    private var trk: RecordingPoster!
    private var firstParty: RecordingPoster!
    private var sdk: AppRefer!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.apprefer.consent.\(UUID().uuidString)")!
        status = FakeStatus(.undetermined)
        trk = RecordingPoster()
        firstParty = RecordingPoster()
        sdk = AppRefer(
            config: AppReferConfig(apiKey: "pk_test_x"),
            storage: AppReferStorage(defaults: defaults, keychain: FakeDeviceIdKeychain()),
            trackingStatus: status, trackingClient: trk, firstPartyClient: firstParty
        )
    }

    func testBaseURLFollowsConsent() {
        XCTAssertEqual(AppReferTrackingConsent.granted.baseURL, "https://trk.apprefer.com")
        XCTAssertEqual(AppReferTrackingConsent.denied.baseURL, "https://apprefer.com")
        XCTAssertEqual(AppReferTrackingConsent.undetermined.baseURL, "https://apprefer.com")
    }

    func testFirstOpenWithoutATTGoesToFirstPartyHostOnly() async {
        _ = await sdk._configure()
        XCTAssertEqual(trk.calls.count, 0)
        XCTAssertEqual(firstParty.calls.map(\.path), ["/api/track/configure"])
        XCTAssertEqual(firstParty.calls[0].body["tracking_consent"] as? String, "undetermined")
        XCTAssertNil(firstParty.calls[0].body["idfa"])
    }

    func testFirstOpenWithATTGoesToTrackingHostOnly() async {
        status.set(.granted)
        _ = await sdk._configure()
        XCTAssertEqual(firstParty.calls.count, 0)
        XCTAssertEqual(trk.calls.first?.body["tracking_consent"] as? String, "granted")
    }

    func testAnswerIsReportedOnceToTheHostForTheNewValue() async {
        _ = await sdk._configure()
        status.set(.granted)
        let upgraded: [String: Any] = ["sdkEnabled": true, "attribution": ["network": "meta", "matchType": "probabilistic"]]
        trk.response = upgraded
        let attribution = await sdk.syncTrackingConsent()
        XCTAssertEqual(attribution?.network, "meta")
        XCTAssertEqual(trk.calls.map(\.path), ["/api/track/configure"])
        XCTAssertEqual(trk.calls[0].body["tracking_consent"] as? String, "granted")
        XCTAssertNil(trk.calls[0].body["asa_token"])
        // Unchanged: nothing more is sent, on sync or on the next launch's configure.
        _ = await sdk.syncTrackingConsent()
        _ = await sdk._configure()
        XCTAssertEqual(trk.calls.count, 1)
        XCTAssertEqual(firstParty.calls.count, 1)
        // Later revoked in Settings: reported to the first-party host.
        status.set(.denied)
        _ = await sdk.syncTrackingConsent()
        XCTAssertEqual(firstParty.calls.last?.body["tracking_consent"] as? String, "denied")
        XCTAssertEqual(trk.calls.count, 1)
    }

    func testFailedReportIsRetriedNextTime() async {
        _ = await sdk._configure()
        status.set(.denied)
        firstParty.response = nil
        _ = await sdk.syncTrackingConsent()
        firstParty.response = ["sdkEnabled": true]
        _ = await sdk.syncTrackingConsent()
        _ = await sdk.syncTrackingConsent()
        XCTAssertEqual(firstParty.calls.filter { $0.body["tracking_consent"] as? String == "denied" }.count, 2)
    }

    func testEventsAndUserLinkFollowConsentAndAdvancedMatchingNeedsATT() async {
        _ = await sdk._configure()
        await sdk._trackEventForTesting("level_up")
        await sdk._setUserIdForTesting("user-1")
        await sdk._setAdvancedMatchingForTesting(email: "a@example.com")
        XCTAssertEqual(trk.calls.count, 0)
        XCTAssertEqual(firstParty.calls.map(\.path), ["/api/track/configure", "/api/track/event", "/api/track/event"])

        status.set(.granted)
        await sdk._trackEventForTesting("level_up")
        await sdk._setAdvancedMatchingForTesting(email: "a@example.com")
        XCTAssertEqual(trk.calls.map { $0.body["event_name"] as? String }, ["level_up", "_advanced_matching"])
    }

    func testBillingClientReadsHostsPerRequest() {
        let consent = FakeStatus(.denied)
        let client = BillingAPIClient(
            baseURLProvider: { [consent.current().baseURL] }, apiKey: { "pk" }, transport: URLSessionBillingTransport()
        )
        XCTAssertEqual(client.baseURLs, ["https://apprefer.com"])
        consent.set(.granted)
        XCTAssertEqual(client.baseURLs, ["https://trk.apprefer.com"])
    }
}
