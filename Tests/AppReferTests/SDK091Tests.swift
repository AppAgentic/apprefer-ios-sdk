import XCTest
@testable import AppRefer

private actor Poster091: AppReferPosting {
    var calls: [(String, [String: Any])] = []
    var status: Int? = 429
    var cancels = 0
    var blocked = false
    var entered = false
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? {
        calls.append((path, body))
        entered = true
        while blocked && !Task.isCancelled { await Task.yield() }
        return path.contains("conversion-value") ? ["fine": 5, "coarse": "high"] : ["attribution": NSNull()]
    }
    func event(_ body: [String: Any]) async -> Int? { calls.append(("event", body)); return status }
    func cancel() { cancels += 1; blocked = false }
    func setStatus(_ value: Int?) { status = value }
    func setBlocked() { blocked = true; entered = false }
    func count() -> Int { calls.count }
    func bodies() -> [[String: Any]] { calls.map { $0.1 } }
}
private actor Updater091: ConversionValueUpdating {
    var calls = 0
    func update(fine: Int, coarse: AppReferCoarseValue) async { calls += 1 }
    func count() -> Int { calls }
}
/// Records Support session bodies so tests can see whether the device id was sent.
private final class SupportCapture091: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _sessionBodies: [[String: Any]] = []
    static var sessionBodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _sessionBodies }
    static func clear() { lock.lock(); _sessionBodies = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isSession = request.url!.path.hasSuffix("/session")
        if isSession, request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            }
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            Self.lock.lock(); Self._sessionBodies.append(body); Self.lock.unlock()
        }
        let reply = isSession ? "{\"session\":\"support-091b\"}" : "{\"conversations\":[]}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class SupportProtocol091: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = request.url!.path.hasSuffix("/session") ? "{\"session\":\"support-091\"}" : "{\"conversations\":[]}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(data.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class SDK091Tests: XCTestCase {
    private func fixture() -> (AppRefer, AppReferStorage, Poster091, Updater091) {
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let poster = Poster091(); let updater = Updater091()
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster, conversionUpdater: updater)
        return (sdk, storage, poster, updater)
    }
    func testIdentitySurvivesAccountSwitchRestartAndRetry() async throws {
        let (sdk, storage, poster, _) = fixture()
        storage.setUserId("A")
        _ = await sdk._trackEvent("signup", properties: nil, revenue: nil, currency: nil)
        var events = try JSONDecoder().decode([PendingProductEvent].self, from: storage.pendingEvents!)
        let original = events[0].id
        let body = try JSONSerialization.jsonObject(with: events[0].body) as! [String: Any]
        XCTAssertEqual(body["app_user_id"] as? String, "A")
        storage.setUserId("B")
        events[0].nextAttempt = .distantPast; storage.pendingEvents = try JSONEncoder().encode(events)
        let next = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        await poster.setStatus(200); await next.flushPendingEvents()
        let bodies = await poster.bodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies.allSatisfy { $0["app_user_id"] as? String == "A" && $0["eventId"] as? String == original })
        await sdk._clearPendingEvents()
    }
    func testAnonymousAndInternalEventsDoNotGainIdentity() async {
        let (sdk, storage, poster, _) = fixture()
        await poster.setStatus(200)
        _ = await sdk._trackEvent("anonymous", properties: nil, revenue: nil, currency: nil)
        storage.setUserId("A")
        _ = await sdk._trackEvent("_internal", properties: nil, revenue: nil, currency: nil)
        await sdk._setUserIdForTesting("B")
        let bodies = await poster.bodies()
        XCTAssertTrue(bodies.allSatisfy { $0["app_user_id"] == nil })
        await sdk._clearPendingEvents()
    }
    func testDisableStopsEveryEntryPointAndClearsQueueUntilConfigureAfterEnable() async {
        let (sdk, storage, poster, updater) = fixture()
        _ = await sdk._configure()
        _ = await sdk._trackEvent("queued", properties: nil, revenue: nil, currency: nil)
        await sdk._setCollectionEnabled(false)
        let before = await poster.count()
        _ = await sdk._configure(); _ = await sdk.syncTrackingConsent()
        await sdk.didBecomeActive(); await sdk.refreshConversionValue(force: true)
        let result = await sdk._trackEvent("blocked", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(result, .dropped); XCTAssertNil(storage.pendingEvents)
        let count = await poster.count(); XCTAssertEqual(count, before)
        let updates = await updater.count(); XCTAssertEqual(updates, 0)
        await sdk._setCollectionEnabled(true)
        await sdk.refreshConversionValue(force: true)
        let stillBefore = await poster.count(); XCTAssertEqual(stillBefore, before)
        _ = await sdk._configure(); await sdk.refreshConversionValue(force: true, allowRecheck: false)
        let after = await poster.count(); XCTAssertGreaterThan(after, before)
        await sdk._clearPendingEvents()
    }
    func testDisabledChoiceSurvivesNewStorageAndReset() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = AppReferStorage(defaults: defaults, keychain: FakeDeviceIdKeychain())
        first.setCollectionEnabled(false)
        let storage = AppReferStorage(defaults: defaults, keychain: FakeDeviceIdKeychain())
        let poster = Poster091()
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        _ = await sdk._configure(); await sdk._reset(); await sdk.refreshConversionValue(force: true)
        let count = await poster.count(); XCTAssertEqual(count, 0)
        XCTAssertFalse(storage.isCollectionEnabled())
        if case .failed = await sdk.attributionResult() {} else { XCTFail("Missing cache must fail") }
    }
    func testDisableCancelsInFlightConversionAndIgnoresLateResponse() async {
        let (sdk, storage, poster, updater) = fixture()
        storage.setConversionValue(fine: 0, coarse: "low")
        await poster.setBlocked()
        let work = Task { await sdk.refreshConversionValue(force: true) }
        while !(await poster.entered) { await Task.yield() }
        await sdk._setCollectionEnabled(false)
        await work.value
        let count = await updater.count(); XCTAssertEqual(count, 0)
        XCTAssertEqual(storage.conversionValue()?.fine, 0)
        let cancels = await poster.cancels; XCTAssertGreaterThan(cancels, 0)
    }
    func testPublicSwitchBeforeConfigurePersistsWithoutSharedInstance() async {
        let previous = AppRefer.replaceSharedForTesting(nil)
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "apprefer_collection_enabled")
        defer { defaults.set(old, forKey: "apprefer_collection_enabled"); _ = AppRefer.replaceSharedForTesting(previous) }
        await AppRefer.setCollectionEnabled(false)
        XCTAssertFalse(AppReferStorage().isCollectionEnabled())
    }
    func testSupportWorksWhileCollectionDisabled() async throws {
        let (sdk, _, _, _) = fixture()
        await sdk._setCollectionEnabled(false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupportProtocol091.self]
        let api = SupportAPI(baseURL: "https://support091.test", session: URLSession(configuration: config))
        await api.configure(apiKey: "pk_test")
        let conversations = try await api.conversations()
        XCTAssertTrue(conversations.isEmpty)
        await api.reset()
    }
    func testDisableCancelsConfigureAndNewConfigurationIsCachedOnly() async {
        let (sdk, _, poster, _) = fixture()
        await poster.setBlocked()
        let work = Task { await sdk._configure() }
        while !(await poster.entered) { await Task.yield() }
        await sdk._setCollectionEnabled(false)
        _ = await work.value
        let before = await poster.count()
        _ = await sdk._configure()
        let after = await poster.count(); XCTAssertEqual(after, before)
        let cancels = await poster.cancels; XCTAssertGreaterThan(cancels, 0)
    }
    func testRealTransportDoesNotStartRequestsWhenCollectionDisabled() async {
        let (_, storage, _, _) = fixture()
        storage.setCollectionEnabled(false)
        let client = AppReferHTTPClient(primaryURL: "https://must-not-contact.invalid", apiKey: "pk", logger: AppReferLogger(debug: false, logLevel: 1), collectionAllowed: { storage.isCollectionEnabled() })
        for path in ["/api/track/configure", "/api/track/conversion-value", "/api/track/event"] {
            let response = await client.post(path, body: [:]); XCTAssertNil(response)
        }
        let status = await client.event([:]); XCTAssertNil(status)
    }

    func testStaleConfigureCannotResumeCollectionAfterReenable() async {
        let (sdk, storage, poster, _) = fixture()
        await sdk._setCollectionEnabled(false)
        await sdk._setCollectionEnabled(true)
        _ = await sdk._configure(expectedCollectionEpoch: AppRefer.collectionEpoch() - 1)
        XCTAssertFalse(storage.isCollectionEnabled())
        let count = await poster.count(); XCTAssertEqual(count, 0)
        _ = await sdk._configure(expectedCollectionEpoch: AppRefer.collectionEpoch())
        XCTAssertTrue(storage.isCollectionEnabled())
        let resumed = await poster.count(); XCTAssertGreaterThan(resumed, 0)
    }

    // MARK: - No device id on Support after reset or with collection off

    func testResetStopsAttributionAndSupportDeviceIdUntilConfigure() async throws {
        let (sdk, storage, poster, updater) = fixture()
        let previous = AppRefer.replaceSharedForTesting(sdk)
        let registration = AppRefer.replaceRegistrationForTesting(apiKey: nil, active: false)
        defer {
            _ = AppRefer.replaceSharedForTesting(previous)
            _ = AppRefer.replaceRegistrationForTesting(apiKey: registration.0, active: registration.1)
            SupportCapture091.clear()
        }
        await poster.setStatus(200)
        // A grants analytics: attribution is configured in this process.
        _ = await AppRefer.configure(apiKey: "pk_test")
        let device = try XCTUnwrap(storage.deviceId())
        XCTAssertEqual(AppRefer.supportDeviceId(storage: storage), device)
        try await Task.sleep(nanoseconds: 300_000_000) // let configure's follow-up refresh settle

        // A signs out.
        await AppRefer.reset()
        XCTAssertNil(AppRefer.supportDeviceId(storage: storage))
        let afterReset = await poster.count()
        let updatesAfterReset = await updater.count()

        // B signs in, never consents; the app only starts Support.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupportCapture091.self]
        let api = SupportAPI(baseURL: "https://support091b.test", session: URLSession(configuration: config),
                             deviceId: { AppRefer.supportDeviceId(storage: storage) })
        await api.reset()
        SupportCapture091.clear()
        await api.configure(apiKey: "pk_test")
        _ = try await api.conversations()
        XCTAssertEqual(SupportCapture091.sessionBodies.count, 1)
        XCTAssertNil(SupportCapture091.sessionBodies.last?["deviceId"])

        // Nothing on the attribution side sends until configure runs again.
        await sdk.didBecomeActive()
        await AppRefer.trackingConsentDidChange()
        await AppRefer.updateConversionValue()
        await AppRefer.setUserId("B")
        await AppRefer.setAdvancedMatching(email: "b@example.test")
        let event = await AppRefer.trackEventResult("signed_out")
        XCTAssertEqual(event, .dropped) // before B consents: never queued or sent later
        await AppRefer.trackEvent("signed_out_fire_and_forget")
        XCTAssertNil(storage.pendingEvents)
        await sdk.flushPendingEvents()
        try await Task.sleep(nanoseconds: 100_000_000)
        let stillAfterReset = await poster.count(); XCTAssertEqual(stillAfterReset, afterReset)
        let updates = await updater.count(); XCTAssertEqual(updates, updatesAfterReset)

        // B consents: configure again links Support to the install once more.
        _ = await AppRefer.configure(apiKey: "pk_test")
        XCTAssertEqual(AppRefer.supportDeviceId(storage: storage), device)
        _ = try await api.conversations()
        XCTAssertEqual(SupportCapture091.sessionBodies.last?["deviceId"] as? String, device)
        let resumed = await AppRefer.trackEventResult("signup")
        XCTAssertEqual(resumed, .sent)
        let sent = await poster.bodies().compactMap { $0["event_name"] as? String }
        XCTAssertFalse(sent.contains("signed_out"))
        XCTAssertFalse(sent.contains("signed_out_fire_and_forget"))

        // Collection withdrawn: Support stops sending the device id.
        await AppRefer.setCollectionEnabled(false)
        XCTAssertNil(AppRefer.supportDeviceId(storage: storage))
        let sessionsBefore = SupportCapture091.sessionBodies.count
        _ = try await api.conversations()
        XCTAssertEqual(SupportCapture091.sessionBodies.count, sessionsBefore + 1)
        XCTAssertNil(SupportCapture091.sessionBodies.last?["deviceId"])
        await api.reset()
        await sdk._clearPendingEvents()
    }

    func testStaleConfigureFromBeforeResetDoesNotRestartAttribution() async {
        let (sdk, _, poster, _) = fixture()
        _ = await sdk._configure()
        await sdk._reset()
        let before = await poster.count()
        _ = await sdk._configure(expectedAccountEpoch: AppRefer.accountEpoch() - 1)
        await sdk.refreshConversionValue(force: true, allowRecheck: false)
        let result = await sdk._trackEvent("stale", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(result, .dropped)
        let after = await poster.count(); XCTAssertEqual(after, before)
        await sdk._clearPendingEvents()
    }

    func testSupportOnlySendsNoDeviceId() async throws {
        let (_, storage, _, _) = fixture()
        let registration = AppRefer.replaceRegistrationForTesting(apiKey: nil, active: false)
        defer { _ = AppRefer.replaceRegistrationForTesting(apiKey: registration.0, active: registration.1); SupportCapture091.clear() }
        XCTAssertNil(AppRefer.supportDeviceId(storage: storage))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupportCapture091.self]
        let api = SupportAPI(baseURL: "https://support091b.test", session: URLSession(configuration: config),
                             deviceId: { AppRefer.supportDeviceId(storage: storage) })
        await api.reset()
        SupportCapture091.clear()
        await api.configure(apiKey: "pk_support_only")
        _ = try await api.conversations()
        XCTAssertEqual(SupportCapture091.sessionBodies.count, 1)
        XCTAssertNil(SupportCapture091.sessionBodies.first?["deviceId"])
        await api.reset()
    }

}
