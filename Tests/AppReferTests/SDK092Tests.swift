import XCTest
@testable import AppRefer

private actor Poster092: AppReferPosting {
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? { ["attribution": NSNull()] }
    func event(_ body: [String: Any]) async -> Int? { 200 }
}

/// Records every Support request; mints a new session token for each POST without one.
private final class SupportRecorder092: URLProtocol, @unchecked Sendable {
    struct Call { let method: String; let path: String; let session: String?; let body: [String: Any] }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _calls: [Call] = []
    private nonisolated(unsafe) static var minted = 0
    private nonisolated(unsafe) static var _failDeletes = false
    static var failDeletes: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failDeletes }
        set { lock.lock(); _failDeletes = newValue; lock.unlock() }
    }
    static var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    static func clear() { lock.lock(); _calls = []; _failDeletes = false; lock.unlock() }
    static func pushPosts() -> [Call] { calls.filter { $0.method == "POST" && $0.path.hasSuffix("/push-token") } }
    static func deletes(_ session: String?) -> [Call] { calls.filter { $0.method == "DELETE" && $0.path.hasSuffix("/session") && $0.session == session } }
    static func sessionPosts() -> [Call] { calls.filter { $0.method == "POST" && $0.path.hasSuffix("/session") } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        let header = request.value(forHTTPHeaderField: "X-AppRefer-Support-Session")
        Self.lock.lock()
        Self._calls.append(Call(method: method, path: path, session: header, body: body))
        var reply = "{}"
        var status = 200
        if path.hasSuffix("/session"), method == "DELETE", Self._failDeletes { status = 500 }
        if path.hasSuffix("/session"), method == "POST" {
            if let header { reply = "{\"session\":\"\(header)\"}" } else { Self.minted += 1; reply = "{\"session\":\"ars_092_\(Self.minted)\"}" }
        } else if path.hasSuffix("/conversations") { reply = "{\"conversations\":[]}" }
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SDK092Tests: XCTestCase {
    private var env: BillingTestEnvironment!
    override func setUp() { super.setUp(); env = BillingTestEnvironment() }
    override func tearDown() { env.cleanUp(); super.tearDown() }

    private func attributionStorage() -> AppReferStorage {
        AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
    }

    private func billingBodies(_ transport: MockBillingTransport, _ path: String) -> [[String: Any]] {
        transport.requests(to: path).compactMap(\.jsonBody)
    }

    // MARK: - 1. Billing follows the Support device id gate

    func testBillingSendsDeviceIdNormallyAndNoneWhileCollectionIsOff() async throws {
        let storage = attributionStorage()
        let registration = AppRefer.replaceRegistrationForTesting(apiKey: "pk_test", active: true)
        defer { _ = AppRefer.replaceRegistrationForTesting(apiKey: registration.0, active: registration.1) }
        let device = try XCTUnwrap(storage.deviceId())

        // Normal: customers and purchases carry the install id.
        let on = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let engine = env.engine(transport: on, appUserId: "user_1", appreferId: { AppRefer.supportDeviceId(storage: storage) })
        await engine.setAttributes(["$email": "a@example.com", "$idfv": "IDFV-1"])
        _ = await engine.customerInfo(policy: .fetchCurrent)
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()))
        XCTAssertEqual(billingBodies(on, "/api/billing/v1/customers").first?["appreferId"] as? String, device)
        XCTAssertEqual(billingBodies(on, "/api/billing/v1/customers").first?["attributes"] as? [String: String],
                       ["$email": "a@example.com", "$idfv": "IDFV-1"])
        XCTAssertEqual(billingBodies(on, "/api/billing/v1/purchases").first?["appreferId"] as? String, device)

        // Collection off: no device id or device attribute, purchases and entitlements still work.
        storage.setCollectionEnabled(false)
        let offEnv = BillingTestEnvironment(); defer { offEnv.cleanUp() }
        let off = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let offEngine = offEnv.engine(transport: off, appUserId: "user_1", appreferId: { AppRefer.supportDeviceId(storage: storage) })
        await offEngine.setAttributes(["$email": "a@example.com", "$idfa": "IDFA-1", "$fbAnonId": "fb"])
        let info = await offEngine.customerInfo(policy: .fetchCurrent)
        let bought = await offEngine.process(BillingFixtures.update(BillingFixtures.transaction(id: "2000000000000002"), counter: FinishCounter()))
        let customers = billingBodies(off, "/api/billing/v1/customers")
        let purchases = billingBodies(off, "/api/billing/v1/purchases")
        XCTAssertEqual(customers.count, 1); XCTAssertEqual(purchases.count, 1)
        XCTAssertNil(customers[0]["appreferId"])
        XCTAssertEqual(customers[0]["attributes"] as? [String: String], ["$email": "a@example.com"])
        XCTAssertNil(purchases[0]["appreferId"])
        XCTAssertEqual(purchases[0]["signedTransaction"] as? String, "jws.2000000000000002.sig")
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(bought.entitlements["premium"]?.isActive, true)
    }

    func testUnsavedOffPauseAlsoWithholdsTheDeviceId() throws {
        let storage = attributionStorage()
        let registration = AppRefer.replaceRegistrationForTesting(apiKey: "pk_test", active: true)
        defer { _ = AppRefer.replaceRegistrationForTesting(apiKey: registration.0, active: registration.1) }
        XCTAssertNotNil(AppRefer.supportDeviceId(storage: storage))
        // Turned off then on again without configure: still paused.
        storage.setCollectionEnabled(false)
        storage.setCollectionEnabled(true)
        XCTAssertNil(AppRefer.supportDeviceId(storage: storage))

        // The default gate (what Billing and Support use) reads the SDK's own storage.
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: Poster092(), firstPartyClient: Poster092())
        let previous = AppRefer.replaceSharedForTesting(sdk)
        defer { _ = AppRefer.replaceSharedForTesting(previous) }
        XCTAssertFalse(AppRefer.installLinkAllowed())
        XCTAssertNil(AppRefer.supportDeviceId())
        storage.resumeCollection()
        XCTAssertTrue(AppRefer.installLinkAllowed())
    }

    func testBillingAfterResetSendsNoDeviceIdUntilConfigure() async throws {
        let storage = attributionStorage()
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: Poster092(), firstPartyClient: Poster092())
        let previous = AppRefer.replaceSharedForTesting(sdk)
        let registration = AppRefer.replaceRegistrationForTesting(apiKey: nil, active: false)
        defer {
            _ = AppRefer.replaceSharedForTesting(previous)
            _ = AppRefer.replaceRegistrationForTesting(apiKey: registration.0, active: registration.1)
        }
        _ = await AppRefer.configure(apiKey: "pk_test")
        let device = try XCTUnwrap(storage.deviceId())
        XCTAssertEqual(AppRefer.supportDeviceId(storage: storage), device)
        await AppRefer.reset()

        // A purchase queued before the reset still holds the device id on disk.
        let queue = env.queue()
        queue.add(PendingPurchase(
            transactionId: "2000000000000009", productId: "pro_yearly", appUserId: "user_b", appreferId: device,
            signedTransaction: "jws.queued.sig", enqueuedAt: BillingFixtures.now, attempts: 0
        ))
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_b"))
        let engine = env.engine(transport: transport, appUserId: "user_b", queue: queue,
                                appreferId: { AppRefer.supportDeviceId(storage: storage) })
        _ = await engine.customerInfo(policy: .fetchCurrent)
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()))
        await engine.drainQueue()
        XCTAssertTrue(queue.isEmpty)
        let customers = billingBodies(transport, "/api/billing/v1/customers")
        let purchases = billingBodies(transport, "/api/billing/v1/purchases")
        XCTAssertFalse(customers.isEmpty); XCTAssertEqual(purchases.count, 2)
        XCTAssertTrue((customers + purchases).allSatisfy { $0["appreferId"] == nil })
        XCTAssertTrue(purchases.contains { $0["signedTransaction"] as? String == "jws.queued.sig" })

        // Configure for the next user: the device id is sent again, and the customer
        // registered without it is linked once.
        _ = await AppRefer.configure(apiKey: "pk_test")
        _ = await engine.customerInfo(policy: .fetchCurrent)
        _ = await engine.customerInfo(policy: .fetchCurrent)
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(id: "2000000000000003"), counter: FinishCounter()))
        let linked = billingBodies(transport, "/api/billing/v1/customers")
        XCTAssertEqual(linked.count, customers.count + 1, "one re-registration, then GETs")
        XCTAssertEqual(linked.last?["appreferId"] as? String, device)
        XCTAssertEqual(billingBodies(transport, "/api/billing/v1/purchases").last?["appreferId"] as? String, device)
        await sdk._clearPendingEvents()
    }

    func testBillingOnlyAppSendsNoDeviceId() {
        let registration = AppRefer.replaceRegistrationForTesting(apiKey: nil, active: false)
        defer { _ = AppRefer.replaceRegistrationForTesting(apiKey: registration.0, active: registration.1) }
        XCTAssertNil(AppRefer.supportDeviceId(storage: attributionStorage()))
        XCTAssertEqual(BillingEngine.sendable(["$gpsAdId": "g", "$ip": "1.2.3.4", "$displayName": "Sam"], linked: false), ["$displayName": "Sam"])
    }

    // MARK: - 3/4. Billing device id is tied to the account; identify sends link

    func testDeviceIdOnlyForTheBillingUserSetAfterTheLastReset() async throws {
        let epoch = Counter092()
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_a"))
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let gate = Gate092()
        let engine = env.engine(transport: transport, storage: storage, appreferId: { gate.open ? "device-abc" : nil },
                                accountEpoch: { epoch.value })
        // Registered while the gate was closed (collection off): unlinked.
        gate.open = false
        _ = await engine.customerInfo(policy: .fetchCurrent)
        // reset(), then configure again: the gate opens, but user_a is the previous account.
        epoch.value = 1; gate.open = true
        _ = await engine.customerInfo(policy: .fetchCurrent)
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()))
        let queue = env.queue()
        XCTAssertTrue(queue.isEmpty)
        let before = billingBodies(transport, "/api/billing/v1/customers") + billingBodies(transport, "/api/billing/v1/purchases")
        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(before.allSatisfy { $0["appreferId"] == nil }, "no device id or re-link for the previous account")
        XCTAssertEqual(billingBodies(transport, "/api/billing/v1/customers").count, 1, "no re-link registration")

        // The next account signs in to Billing: its requests carry the device id.
        transport.setHandler { request in
            let user = request.jsonBody?["appUserId"] as? String ?? "user_b"
            return (Data(BillingFixtures.customerJSON(appUserId: user).utf8), 200)
        }
        _ = try await engine.logIn("user_b")
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(id: "2000000000000005"), counter: FinishCounter()))
        let customers = billingBodies(transport, "/api/billing/v1/customers")
        XCTAssertEqual(customers.last?["appUserId"] as? String, "user_b")
        XCTAssertEqual(customers.last?["appreferId"] as? String, "device-abc")
        XCTAssertEqual(billingBodies(transport, "/api/billing/v1/purchases").last?["appreferId"] as? String, "device-abc")

        // A purchase owned by someone other than the current user never gets it.
        let foreign = BillingFixtures.transaction(id: "2000000000000006", appAccountToken: BillingFixtures.otherAccountToken)
        storage.setAccountToken(BillingFixtures.otherAccountToken.uuidString, for: "user_a")
        _ = await engine.process(BillingFixtures.update(foreign, counter: FinishCounter()))
        let last = billingBodies(transport, "/api/billing/v1/purchases").last
        XCTAssertEqual(last?["appUserId"] as? String, "user_a")
        XCTAssertNil(last?["appreferId"])
    }

    func testIdentifySendsLinkFromTheGate() async throws {
        let gate = Gate092()
        gate.open = false
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_1"))
        let storage = env.storage()
        _ = try XCTUnwrap(storage.anonymousId())
        let engine = env.engine(transport: transport, storage: storage, linkAllowed: { gate.open })
        _ = try await engine.logIn("user_1")
        XCTAssertEqual(billingBodies(transport, "/api/billing/v1/identify").last?["link"] as? Bool, false)
        gate.open = true
        _ = await engine.logOut()
        _ = try await engine.logIn("user_2")
        XCTAssertEqual(billingBodies(transport, "/api/billing/v1/identify").last?["link"] as? Bool, true)
    }

    // MARK: - 2. Support clearIdentity

    private func supportAPI(_ userStorage: AppReferStorage, deviceId: String? = nil) -> SupportAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupportRecorder092.self]
        return SupportAPI(baseURL: "https://support092.test", session: URLSession(configuration: config),
                          deviceId: { deviceId }, userStorage: userStorage)
    }

    func testClearIdentityRevokesTheSessionAndStartsAnAnonymousOne() async throws {
        let userStorage = attributionStorage()
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage, deviceId: "install-1")
        await api.reset()
        SupportRecorder092.clear()
        await api.configure(apiKey: "pk_test")
        await api.setIdentity(name: "Sam", email: "sam@example.test")
        _ = try await api.conversations()
        let first = try XCTUnwrap(SupportRecorder092.sessionPosts().last)
        XCTAssertEqual(first.body["appUserId"] as? String, "acct_A")
        XCTAssertEqual(first.body["deviceId"] as? String, "install-1")
        XCTAssertEqual(first.body["name"] as? String, "Sam")
        let oldSession = try XCTUnwrap(SupportRecorder092.calls.last?.session)

        await api.clearIdentity()
        let fresh = try XCTUnwrap(SupportRecorder092.sessionPosts().last)
        XCTAssertNil(fresh.session, "a new session, not an update of the old one")
        XCTAssertNil(fresh.body["appUserId"]); XCTAssertNil(fresh.body["name"]); XCTAssertNil(fresh.body["email"])
        XCTAssertNil(fresh.body["deviceId"], "no install id: it would link the session back to the account")
        let displayName = await api.displayName
        XCTAssertNil(displayName)
        XCTAssertTrue(userStorage.supportIdentityCleared)
        XCTAssertEqual(userStorage.getUserId(), "acct_A", "attribution's user id is untouched")

        // The old session is revoked through the durable revocation path.
        await api.revokePending(using: "pk_test")
        XCTAssertFalse(SupportRecorder092.deletes(oldSession).isEmpty)

        // The same user id stored again (configure on the next launch) keeps the anonymous session.
        userStorage.setUserId("acct_A")
        let posts = SupportRecorder092.sessionPosts().count
        _ = try await api.conversations()
        XCTAssertEqual(SupportRecorder092.sessionPosts().count, posts)
        let clearedSession = try XCTUnwrap(SupportRecorder092.calls.last?.session)
        XCTAssertNotEqual(clearedSession, oldSession)

        // Another account without reset: the cleared session is never handed over. It is
        // revoked and a fresh session is minted for B.
        userStorage.setUserId("acct_B")
        XCTAssertFalse(userStorage.supportIdentityCleared)
        _ = try await api.conversations()
        let forB = try XCTUnwrap(SupportRecorder092.sessionPosts().last)
        XCTAssertNil(forB.session, "minted, not an upgrade of the cleared session")
        XCTAssertEqual(forB.body["appUserId"] as? String, "acct_B")
        XCTAssertEqual(forB.body["deviceId"] as? String, "install-1")
        XCTAssertFalse(SupportRecorder092.calls.contains { $0.session == clearedSession && $0.body["appUserId"] as? String == "acct_B" })
        XCTAssertNotEqual(SupportRecorder092.calls.last?.session, clearedSession)
        await api.revokePending(using: "pk_test")
        XCTAssertFalse(SupportRecorder092.deletes(clearedSession).isEmpty)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SupportAPI.clearedSessionKey))
        await api.reset()
    }

    func testPushTokenMovesOnlyAfterTheOldSessionIsRevoked() async throws {
        let userStorage = attributionStorage()
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage)
        await api.reset()
        SupportRecorder092.clear()
        await api.configure(apiKey: "pk_test")
        try await api.registerPushToken("abcd", sandbox: true)
        let oldSession = try XCTUnwrap(SupportRecorder092.calls.last?.session)
        XCTAssertEqual(SupportRecorder092.pushPosts().count, 1)

        // The revocation fails (offline): the token stays on no new session yet.
        SupportRecorder092.failDeletes = true
        await api.clearIdentity()
        await api.revokePending(using: "pk_test")
        XCTAssertEqual(SupportRecorder092.pushPosts().count, 1, "not registered on the new session before the old one is revoked")
        // The app registers it again meanwhile: still deferred.
        try await api.registerPushToken("abcd", sandbox: true)
        XCTAssertEqual(SupportRecorder092.pushPosts().count, 1)
        // Let the revocation pass that registration started finish (it fails too).
        try await Task.sleep(nanoseconds: 300_000_000)

        // The next revocation pass succeeds: the token moves to the new session.
        SupportRecorder092.failDeletes = false
        await api.revokePending(using: "pk_test")
        XCTAssertGreaterThanOrEqual(SupportRecorder092.deletes(oldSession).count, 2)
        let push = try XCTUnwrap(SupportRecorder092.pushPosts().last)
        XCTAssertEqual(SupportRecorder092.pushPosts().count, 2)
        XCTAssertEqual(push.body["token"] as? String, "abcd")
        XCTAssertNotNil(push.session); XCTAssertNotEqual(push.session, oldSession)
        let deleteIndex = try XCTUnwrap(SupportRecorder092.calls.lastIndex { $0.method == "DELETE" })
        let pushIndex = try XCTUnwrap(SupportRecorder092.calls.lastIndex { $0.path.hasSuffix("/push-token") })
        XCTAssertLessThan(deleteIndex, pushIndex)
        XCTAssertNil(SupportRecorder092.sessionPosts().last?.body["appUserId"])
        await api.reset()
        UserDefaults.standard.removeObject(forKey: "apprefer_support_push_token")
    }

    func testResetBeforeTheRevocationSucceedsNeverMovesThePushToken() async throws {
        let userStorage = attributionStorage()
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage)
        await api.reset()
        SupportRecorder092.clear()
        await api.configure(apiKey: "pk_test")
        // Revocations left by earlier tests may still hold the token (0.9.3 defers it then).
        await api.revokePending(using: "pk_test")
        SupportRecorder092.clear()
        try await api.registerPushToken("abcd", sandbox: true)
        SupportRecorder092.failDeletes = true
        await api.clearIdentity()
        await api.reset() // the next account
        SupportRecorder092.failDeletes = false
        await api.revokePending(using: "pk_test")
        XCTAssertEqual(SupportRecorder092.pushPosts().count, 1, "never moved to the next account")
    }

    func testResetEndsAnIdentityClear() {
        let storage = attributionStorage()
        storage.setUserId("acct_A")
        storage.supportIdentityCleared = true
        storage.clearUser()
        XCTAssertFalse(storage.supportIdentityCleared)
    }
}

private final class Counter092: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private final class Gate092: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = true
    var open: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _open }
        set { lock.lock(); _open = newValue; lock.unlock() }
    }
}
