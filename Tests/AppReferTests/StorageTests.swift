import XCTest
@testable import AppRefer

final class StorageTests: XCTestCase {
    private var storage: AppReferStorage!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.apprefer.test.\(UUID().uuidString)")!
        storage = AppReferStorage(defaults: testDefaults)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: testDefaults.description)
        super.tearDown()
    }

    func testMatchRequestAttempted_defaultsFalse() {
        XCTAssertFalse(storage.isMatchRequestAttempted())
    }

    func testMatchRequestAttempted_setAndGet() {
        storage.setMatchRequestAttempted(true)
        XCTAssertTrue(storage.isMatchRequestAttempted())
    }

    func testSdkEnabled_defaultsTrue() {
        XCTAssertTrue(storage.isSdkEnabled())
    }

    func testSdkEnabled_setAndGet() {
        storage.setSdkEnabled(false)
        XCTAssertFalse(storage.isSdkEnabled())
    }

    func testInstallEventSent_defaultsFalse() {
        XCTAssertFalse(storage.isInstallEventSent())
    }

    func testInstallEventSent_setAndGet() {
        storage.setInstallEventSent(true)
        XCTAssertTrue(storage.isInstallEventSent())
    }

    func testUserId_defaultsNil() {
        XCTAssertNil(storage.getUserId())
    }

    func testUserId_setAndGet() {
        storage.setUserId("user_123")
        XCTAssertEqual(storage.getUserId(), "user_123")
    }

    func testAttributionCache_defaultsNil() {
        XCTAssertNil(storage.getAttributionCache())
    }

    func testAttributionCache_setAndGet() {
        let json = "{\"network\":\"meta\",\"match_type\":\"click_id\"}"
        storage.setAttributionCache(json)
        XCTAssertEqual(storage.getAttributionCache(), json)
    }

    func testGetCachedAttribution_parsesValidJson() {
        let json = """
        {"network":"google","match_type":"click_id","gclid":"abc","query_params":{},"created_at":"2024-01-01T00:00:00Z"}
        """
        storage.setAttributionCache(json)
        let attribution = storage.getCachedAttribution()

        XCTAssertNotNil(attribution)
        XCTAssertEqual(attribution?.network, "google")
        XCTAssertEqual(attribution?.gclid, "abc")
    }

    func testGetCachedAttribution_returnsNilForInvalidJson() {
        storage.setAttributionCache("not-json")
        XCTAssertNil(storage.getCachedAttribution())
    }

    func testFirstRunDate_setsOnFirstCall() {
        let date1 = storage.getFirstRunDate()
        let date2 = storage.getFirstRunDate()
        XCTAssertEqual(date1, date2) // Same value on subsequent calls
        XCTAssertFalse(date1.isEmpty)
    }
}
