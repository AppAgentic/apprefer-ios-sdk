import XCTest
@testable import AppRefer

/// 0.10.1: the APNs environment comes from the app's signing, never from DEBUG.
final class PushEnvironmentTests: XCTestCase {
    /// A profile as Xcode embeds it: a binary CMS envelope around an XML property list.
    static func profile(aps: String?, key: String = "aps-environment") -> Data {
        let entitlements = aps.map { "<key>\(key)</key><string>\($0)</string>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>Fixture</string>
        <key>Entitlements</key><dict>\(entitlements)<key>application-identifier</key><string>TEAM.com.example</string></dict>
        </dict></plist>
        """
        return Data([0x30, 0x82, 0x2f, 0x11, 0x06, 0x09, 0x2a, 0x86, 0x48]) + Data(xml.utf8) + Data([0xa0, 0x82, 0x0d, 0x3c, 0x00])
    }

    func testDevelopmentSignedReleaseIsSandbox() {
        // A Release configuration signed with a development profile: the profile decides.
        XCTAssertEqual(PushEnvironmentDetector.environment(profile: Self.profile(aps: "development"), isSimulator: false), .sandbox)
    }

    func testProductionSignedDebugAndReleaseAreProduction() {
        // Ad Hoc / Enterprise profiles carry production whatever the build configuration.
        XCTAssertEqual(PushEnvironmentDetector.environment(profile: Self.profile(aps: "production"), isSimulator: false), .production)
    }

    func testMacOSEntitlementKey() {
        XCTAssertEqual(PushEnvironmentDetector.apsEnvironment(inProfile: Self.profile(aps: "development", key: "com.apple.developer.aps-environment")), "development")
    }

    func testNoProfileIsProduction() {
        // App Store and TestFlight builds have no embedded profile.
        XCTAssertEqual(PushEnvironmentDetector.environment(profile: nil, isSimulator: false), .production)
    }

    func testMalformedProfilesAreProduction() {
        let cases: [Data] = [
            Data(),
            Data("garbage".utf8),
            Data("<?xml version=\"1.0\"?><plist><dict><key>Entitlements".utf8), // truncated, no </plist>
            Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Entitlements</key><string>x</string></dict></plist>".utf8),
            Data("</plist><?xml version=\"1.0\"?>".utf8), // markers out of order
            Self.profile(aps: nil),
            Self.profile(aps: "staging"),
            Data(repeating: 0x41, count: PushEnvironmentDetector.maxProfileBytes + 1),
        ]
        for data in cases {
            XCTAssertNil(PushEnvironmentDetector.apsEnvironment(inProfile: data))
            XCTAssertEqual(PushEnvironmentDetector.environment(profile: data, isSimulator: false), .production)
        }
    }

    func testOversizedProfileIsNotParsed() {
        var data = Self.profile(aps: "development")
        data.append(Data(repeating: 0, count: PushEnvironmentDetector.maxProfileBytes))
        XCTAssertNil(PushEnvironmentDetector.apsEnvironment(inProfile: data))
    }

    func testSimulatorIsSandbox() {
        XCTAssertEqual(PushEnvironmentDetector.environment(profile: nil, isSimulator: true), .sandbox)
        XCTAssertEqual(PushEnvironmentDetector.environment(profile: Self.profile(aps: "production"), isSimulator: true), .sandbox)
    }

    func testEmbeddedProfileIsReadFromTheBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pe-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(Bundle(url: dir))
        XCTAssertNil(PushEnvironmentDetector.embeddedProfile(bundle: bundle))
        #if os(macOS)
        let url = dir.appendingPathComponent("Contents/embedded.provisionprofile")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #else
        let url = dir.appendingPathComponent("embedded.mobileprovision")
        #endif
        try Self.profile(aps: "development").write(to: url)
        let data = try XCTUnwrap(PushEnvironmentDetector.embeddedProfile(bundle: bundle))
        XCTAssertEqual(PushEnvironmentDetector.environment(profile: data, isSimulator: false), .sandbox)
    }

    func testExplicitOverrideWinsAndDetectionRunsOnce() {
        var calls = 0
        let setting = PushEnvironmentSetting(detect: { calls += 1; return .sandbox })
        XCTAssertEqual(setting.effective, .sandbox)
        XCTAssertEqual(setting.effective, .sandbox)
        XCTAssertEqual(calls, 1)
        setting.override = .production
        XCTAssertEqual(setting.effective, .production)
        setting.override = nil
        XCTAssertEqual(setting.effective, .sandbox)
    }

    #if os(iOS)
    @MainActor
    func testPublicOverrideDrivesReadiness() {
        let support = AppRefer.support
        let before = support.pushEnvironment
        defer { support.pushEnvironment = before }
        let status = AppReferSupportStatus(
            push: .init(ios: .init(configured: true, verified: true, environments: .init(production: true, sandbox: false)), android: .off),
            email: .init(configured: false, receivesReplies: false), helpCentreArticles: 0)
        support.pushEnvironment = .production
        XCTAssertEqual(support.effectivePushEnvironment, .production)
        XCTAssertFalse(SupportAPI.pushSandbox)
        XCTAssertTrue(status.pushReady)
        support.pushEnvironment = .sandbox
        XCTAssertTrue(SupportAPI.pushSandbox)
        XCTAssertFalse(status.pushReady, "the sandbox environment was rejected")
    }
    #endif

    func testReadinessUsesTheGivenEnvironment() {
        let status = AppReferSupportStatus(
            push: .init(ios: .init(configured: true, verified: true, environments: .init(production: false, sandbox: true)), android: .off),
            email: .init(configured: false, receivesReplies: false), helpCentreArticles: 0)
        XCTAssertTrue(status.pushReady(for: .sandbox))
        XCTAssertFalse(status.pushReady(for: .production))
    }
}
