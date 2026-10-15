import XCTest
@testable import AppRefer

private final class FakeUpdater: ConversionValueUpdating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(Int, AppReferCoarseValue)] = []
    func update(fine: Int, coarse: AppReferCoarseValue) async { lock.lock(); calls.append((fine, coarse)); lock.unlock() }
}

private final class PathPoster: AppReferPosting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var paths: [String] = []
    var value: [String: Any]? = ["fine": 0, "coarse": "low"]
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? {
        lock.lock(); paths.append(path); lock.unlock()
        return path == "/api/track/conversion-value" ? value : ["sdkEnabled": true]
    }
}

private struct Denied: TrackingStatusProvider { func current() -> AppReferTrackingConsent { .denied } }

final class ConversionValueTests: XCTestCase {
    private var defaults: UserDefaults!
    private var updater: FakeUpdater!
    private var firstParty: PathPoster!
    private var trk: PathPoster!
    private var sdk: AppRefer!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.apprefer.cv.\(UUID().uuidString)")!
        updater = FakeUpdater()
        firstParty = PathPoster()
        trk = PathPoster()
        sdk = AppRefer(
            config: AppReferConfig(apiKey: "pk_test_x"),
            storage: AppReferStorage(defaults: defaults, keychain: FakeDeviceIdKeychain()),
            trackingStatus: Denied(), trackingClient: trk, firstPartyClient: firstParty, conversionUpdater: updater
        )
    }

    func testRegistersOnFirstCallThenOnlyRaisesTheValue() async {
        await sdk.refreshConversionValue(force: false)
        XCTAssertEqual(updater.calls.map(\.0), [0])
        XCTAssertEqual(updater.calls.first?.1, .low)

        firstParty.value = ["fine": 10, "coarse": "medium"]
        await sdk.refreshConversionValue(force: true)
        firstParty.value = ["fine": 30, "coarse": "high"]
        await sdk.refreshConversionValue(force: true)
        // The server never lowers it, and neither does the device.
        firstParty.value = ["fine": 10, "coarse": "medium"]
        await sdk.refreshConversionValue(force: true)
        XCTAssertEqual(updater.calls.map(\.0), [0, 10, 30])
        XCTAssertEqual(updater.calls.last?.1, .high)
    }

    func testAlwaysUsesTheFirstPartyHostAndThrottlesUnforcedChecks() async {
        await sdk.refreshConversionValue(force: false)
        await sdk.refreshConversionValue(force: false)
        XCTAssertEqual(firstParty.paths.filter { $0 == "/api/track/conversion-value" }.count, 1)
        XCTAssertTrue(trk.paths.isEmpty)
    }

    func testStopsAfterTheThirtyFiveDayWindowAndWhenDisabled() async {
        defaults.set(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-36 * 86400)), forKey: "apprefer_first_run_date")
        await sdk.refreshConversionValue(force: true)
        XCTAssertTrue(updater.calls.isEmpty)

        defaults.removeObject(forKey: "apprefer_first_run_date")
        defaults.set(false, forKey: "apprefer_sdk_enabled")
        await sdk.refreshConversionValue(force: true)
        XCTAssertTrue(updater.calls.isEmpty)
    }

    func testRevenueAndTrialEventsRefreshRightAway() async {
        firstParty.value = ["fine": 10, "coarse": "medium"]
        await sdk._trackEventForTesting("startTrial")
        XCTAssertEqual(updater.calls.map(\.0), [0, 10])
        await sdk._trackEventForTesting("level_up")
        XCTAssertEqual(updater.calls.count, 2)
    }
}
