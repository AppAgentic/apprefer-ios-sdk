import XCTest
@testable import AppRefer

/// Tests for thread-safety issues that could cause EXC_BAD_ACCESS.
/// These tests hammer shared state from multiple concurrent tasks
/// to surface data races.
final class ConcurrencyTests: XCTestCase {

    // MARK: - Storage concurrent access

    /// Hammers UserDefaults read/write from 100 concurrent tasks.
    /// Previously crashed due to @unchecked Sendable without synchronization.
    func testStorageConcurrentReadWrite() async {
        let defaults = UserDefaults(suiteName: "com.apprefer.concurrency.\(UUID().uuidString)")!
        let storage = AppReferStorage(defaults: defaults)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    // Mix of reads and writes
                    storage.setMatchRequestAttempted(i % 2 == 0)
                    _ = storage.isMatchRequestAttempted()
                    storage.setSdkEnabled(i % 3 == 0)
                    _ = storage.isSdkEnabled()
                    storage.setUserId("user_\(i)")
                    _ = storage.getUserId()
                    // Skip getDeviceId() — Keychain requires entitlements on macOS CLI
                    _ = storage.getFirstRunDate()
                }
            }
        }

        // If we get here without EXC_BAD_ACCESS, the test passes
        XCTAssertTrue(true)
        defaults.removePersistentDomain(forName: defaults.description)
    }

    /// Concurrent attribution cache read/write.
    func testStorageConcurrentAttributionCache() async {
        let defaults = UserDefaults(suiteName: "com.apprefer.concurrency.\(UUID().uuidString)")!
        let storage = AppReferStorage(defaults: defaults)

        let json = """
        {"network":"meta","match_type":"click_id","query_params":{},"created_at":"2024-01-01T00:00:00Z"}
        """

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    storage.setAttributionCache(json)
                }
                group.addTask {
                    _ = storage.getCachedAttribution()
                }
            }
        }

        XCTAssertTrue(true)
        defaults.removePersistentDomain(forName: defaults.description)
    }

    // MARK: - Static API concurrent access

    /// Calls getAttribution and getDeviceId concurrently before configure.
    /// Previously could crash due to unsynchronized access to static `shared`.
    func testStaticMethodsBeforeConfigure() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    _ = await AppRefer.getAttribution()
                }
                group.addTask {
                    _ = await AppRefer.getDeviceId()
                }
            }
        }

        // Should return nil without crashing
        let attr = await AppRefer.getAttribution()
        XCTAssertNil(attr)
    }

    /// Calls trackEvent concurrently before configure — should silently no-op, not crash.
    func testConcurrentTrackEventBeforeConfigure() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    await AppRefer.trackEvent("test_\(i)")
                }
            }
        }

        XCTAssertTrue(true) // No crash = pass
    }

    // MARK: - DeviceInfo concurrent collection

    /// Collects device info from multiple tasks simultaneously.
    /// The utsname memory access previously used unsafe pointer rebinding
    /// that could cause EXC_BAD_ACCESS.
    func testDeviceInfoConcurrentCollect() async {
        await withTaskGroup(of: [String: Any].self) { group in
            for _ in 0..<50 {
                group.addTask {
                    return AppReferDeviceInfo.collect()
                }
            }

            for await info in group {
                XCTAssertNotNil(info["platform"])
                XCTAssertEqual(info["platform"] as? String, "ios")
                XCTAssertNotNil(info["model"])
            }
        }
    }
}
