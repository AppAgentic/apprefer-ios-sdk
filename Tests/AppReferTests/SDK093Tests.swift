import XCTest
@testable import AppRefer

/// Records every Support request; mints a new session token for each POST without one.
/// DELETEs can be made slow (to hold a revocation pass open) or fail.
private final class SupportRecorder093: URLProtocol, @unchecked Sendable {
    struct Call { let method: String; let path: String; let session: String?; let body: [String: Any] }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _calls: [Call] = []
    private nonisolated(unsafe) static var minted = 0
    private nonisolated(unsafe) static var _failDeletes = false
    private nonisolated(unsafe) static var _deleteDelay: TimeInterval = 0
    static var failDeletes: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failDeletes }
        set { lock.lock(); _failDeletes = newValue; lock.unlock() }
    }
    static var deleteDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _deleteDelay }
        set { lock.lock(); _deleteDelay = newValue; lock.unlock() }
    }
    static var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    static func clear() { lock.lock(); _calls = []; _failDeletes = false; _deleteDelay = 0; lock.unlock() }
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
        var delay: TimeInterval = 0
        if path.hasSuffix("/session"), method == "DELETE" {
            if Self._failDeletes { status = 500 }
            delay = Self._deleteDelay
        }
        if path.hasSuffix("/session"), method == "POST" {
            if let header { reply = "{\"session\":\"\(header)\"}" } else { Self.minted += 1; reply = "{\"session\":\"ars_093_\(Self.minted)\"}" }
        } else if path.hasSuffix("/conversations") { reply = "{\"conversations\":[]}" }
        Self.lock.unlock()
        let respond = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: respond) } else { respond() }
    }
    override func stopLoading() {}
}

final class SDK093Tests: XCTestCase {
    private var env: BillingTestEnvironment!
    override func setUp() {
        super.setUp()
        env = BillingTestEnvironment()
        SupportRecorder093.clear()
    }
    override func tearDown() {
        env.cleanUp()
        UserDefaults.standard.removeObject(forKey: "apprefer_support_push_token")
        super.tearDown()
    }

    func testVersion() {
        XCTAssertEqual(AppReferVersion.current, "0.12.0")
    }

    private func attributionStorage(keychain: FakeDeviceIdKeychain = FakeDeviceIdKeychain()) -> AppReferStorage {
        AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: keychain)
    }

    private func supportAPI(_ userStorage: AppReferStorage, deviceId: String? = nil, tokenKeychain: DeviceIdKeychain = LiveDeviceIdKeychain()) -> SupportAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupportRecorder093.self]
        return SupportAPI(baseURL: "https://support093.test", session: URLSession(configuration: config),
                          deviceId: { deviceId }, userStorage: userStorage, tokenKeychain: tokenKeychain)
    }

    private func billingBodies(_ transport: MockBillingTransport, _ path: String) -> [[String: Any]] {
        transport.requests(to: path).compactMap(\.jsonBody)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Fix 1: a revocation queued during a pass runs in the same app session

    func testRevocationQueuedWhileAPassRunsIsProcessedWithoutWaitingForForeground() async throws {
        let userStorage = attributionStorage()
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage)
        await api.reset()
        await api.configure(apiKey: "pk_test")
        await api.revokePending(using: "pk_test")
        _ = try await api.conversations()
        let first = try XCTUnwrap(SupportRecorder093.calls.last?.session)
        await api.reset()
        _ = try await api.conversations()
        let second = try XCTUnwrap(SupportRecorder093.calls.last?.session)
        XCTAssertNotEqual(first, second)

        // A pass starts and is held open on the first session's DELETE.
        SupportRecorder093.deleteDelay = 0.4
        let running = Task { await api.revokePending(using: "pk_test") }
        try await waitUntil { !SupportRecorder093.deletes(first).isEmpty }

        // clearIdentity() retires the second session while that pass runs.
        await api.clearIdentity()
        await api.revokePending(using: "pk_test")
        await running.value
        XCTAssertFalse(SupportRecorder093.deletes(second).isEmpty, "processed by a re-run, not left for the next foreground")
        SupportRecorder093.deleteDelay = 0
        await api.reset()
        await api.revokePending(using: "pk_test")
    }

    // MARK: - Fix 3: re-registering a token the old session still holds is deferred

    func testReRegisteredTokenAfterResetWaitsForTheOldSessionsRevocation() async throws {
        let userStorage = attributionStorage()
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage)
        await api.reset()
        await api.configure(apiKey: "pk_test")
        await api.revokePending(using: "pk_test")
        SupportRecorder093.clear()
        try await api.registerPushToken("beef", sandbox: true)
        let oldSession = try XCTUnwrap(SupportRecorder093.calls.last?.session)
        XCTAssertEqual(SupportRecorder093.pushPosts().count, 1)

        // reset() queues the old session's revocation (holding the token, not marked to
        // move); it fails (offline).
        SupportRecorder093.failDeletes = true
        await api.reset()
        await api.revokePending(using: "pk_test")
        userStorage.setUserId("acct_B")
        _ = try await api.conversations()

        // The next account registers the same APNs token: not posted while the old
        // session still holds it.
        try await api.registerPushToken("beef", sandbox: false)
        await api.revokePending(using: "pk_test")
        XCTAssertEqual(SupportRecorder093.pushPosts().count, 1, "the old session still holds the token")

        // The revocation succeeds: the token moves to the current session, with the
        // environment the app registered it with.
        SupportRecorder093.failDeletes = false
        await api.revokePending(using: "pk_test")
        XCTAssertEqual(SupportRecorder093.pushPosts().count, 2)
        let push = try XCTUnwrap(SupportRecorder093.pushPosts().last)
        XCTAssertEqual(push.body["token"] as? String, "beef")
        XCTAssertEqual(push.body["environment"] as? String, "production")
        XCTAssertNotEqual(push.session, oldSession)
        let deleteIndex = try XCTUnwrap(SupportRecorder093.calls.lastIndex { $0.method == "DELETE" && $0.session == oldSession })
        let pushIndex = try XCTUnwrap(SupportRecorder093.calls.lastIndex { $0.path.hasSuffix("/push-token") })
        XCTAssertLessThan(deleteIndex, pushIndex)
        await api.reset()
        await api.revokePending(using: "pk_test")
    }

    func testTokenWithNoHolderIsPostedAtOnce() async throws {
        let userStorage = attributionStorage()
        let api = supportAPI(userStorage)
        await api.reset()
        await api.configure(apiKey: "pk_test")
        await api.revokePending(using: "pk_test")
        SupportRecorder093.clear()
        try await api.registerPushToken("cafe", sandbox: true)
        XCTAssertEqual(SupportRecorder093.pushPosts().count, 1)
        XCTAssertEqual(SupportRecorder093.pushPosts().last?.body["environment"] as? String, "sandbox")
        await api.reset()
        await api.revokePending(using: "pk_test")
    }

    // MARK: - Fix 4: the cleared markers live with the session token (Keychain)

    func testClearedSessionMarkerSurvivesAReinstallWithTheKeychainSession() async throws {
        // One in-memory device Keychain for the attribution flag and the Support session, as on
        // a phone (the live one has no entitlement in a hostless iOS-simulator test bundle).
        let keychain = FakeDeviceIdKeychain()
        let userStorage = attributionStorage(keychain: keychain)
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage, tokenKeychain: keychain)
        await api.reset()
        await api.configure(apiKey: "pk_test")
        await api.revokePending(using: "pk_test")
        _ = try await api.conversations()
        await api.clearIdentity()
        let clearedSession = try XCTUnwrap(keychain.value("apprefer_support_session"))
        XCTAssertTrue(SupportAPI.sessionMintedWhileCleared(keychain: keychain))
        XCTAssertNotNil(keychain.value(SupportAPI.clearedSessionKey), "next to the token")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SupportAPI.clearedSessionKey))
        XCTAssertEqual(keychain.value(AppReferStorage.keySupportIdentityCleared), "1")

        // Reinstall: UserDefaults are gone, the Keychain (session token, markers) survives.
        UserDefaults.standard.removeObject(forKey: "apprefer_support_profile")
        UserDefaults.standard.removeObject(forKey: SupportAPI.clearedSessionKey)
        let reinstalled = attributionStorage(keychain: keychain)
        XCTAssertTrue(reinstalled.supportIdentityCleared, "still knows it was cleared")
        let api2 = supportAPI(reinstalled, deviceId: "install-1", tokenKeychain: keychain)
        await api2.configure(apiKey: "pk_test")
        await api2.revokePending(using: "pk_test")
        // Still anonymous: the surviving session is used without the account.
        _ = try await api2.conversations()
        XCTAssertEqual(SupportRecorder093.calls.last?.session, clearedSession)
        XCTAssertFalse(SupportRecorder093.calls.contains { $0.session == clearedSession && $0.body["appUserId"] != nil })

        // Someone signs in: the cleared session is retired, never handed over.
        reinstalled.setUserId("acct_B")
        _ = try await api2.conversations()
        let forB = try XCTUnwrap(SupportRecorder093.sessionPosts().last)
        XCTAssertNil(forB.session, "minted, not an upgrade of the cleared session")
        XCTAssertEqual(forB.body["appUserId"] as? String, "acct_B")
        XCTAssertFalse(SupportRecorder093.calls.contains { $0.session == clearedSession && $0.body["appUserId"] as? String == "acct_B" })
        await api2.revokePending(using: "pk_test")
        XCTAssertFalse(SupportRecorder093.deletes(clearedSession).isEmpty)
        XCTAssertFalse(SupportAPI.sessionMintedWhileCleared(keychain: keychain))
        await api2.reset()
        await api2.revokePending(using: "pk_test")
    }

    func testOldUserDefaultsMarkersMoveToTheKeychain() {
        // The session marker (in-memory Keychain: also works in a hostless simulator bundle).
        let sessionKeychain = FakeDeviceIdKeychain()
        UserDefaults.standard.set(true, forKey: SupportAPI.clearedSessionKey)
        XCTAssertTrue(SupportAPI.sessionMintedWhileCleared(keychain: sessionKeychain))
        XCTAssertNotNil(sessionKeychain.value(SupportAPI.clearedSessionKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: SupportAPI.clearedSessionKey))
        SupportAPI.setSessionMintedWhileCleared(false, keychain: sessionKeychain)
        XCTAssertFalse(SupportAPI.sessionMintedWhileCleared(keychain: sessionKeychain))

        // The identity-cleared flag.
        let keychain = FakeDeviceIdKeychain()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: AppReferStorage.keySupportIdentityCleared)
        let storage = AppReferStorage(defaults: defaults, keychain: keychain)
        XCTAssertTrue(storage.supportIdentityCleared)
        XCTAssertEqual(keychain.value(AppReferStorage.keySupportIdentityCleared), "1")
        XCTAssertNil(defaults.object(forKey: AppReferStorage.keySupportIdentityCleared))
        storage.clearUser()
        XCTAssertFalse(storage.supportIdentityCleared)
        XCTAssertNil(keychain.value(AppReferStorage.keySupportIdentityCleared))

        // A Keychain that can't save keeps the UserDefaults copy.
        let failing = FakeDeviceIdKeychain()
        failing.failSaves = true
        let fallback = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: failing)
        fallback.supportIdentityCleared = true
        XCTAssertTrue(fallback.supportIdentityCleared)
        fallback.setUserId("acct_B")
        XCTAssertFalse(fallback.supportIdentityCleared)
    }

    // MARK: - Fix 2: the Billing reset gate survives a relaunch

    func testResetMarkerClosesTheGateForThePreviousUserAfterARelaunch() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let before = env.engine(transport: MockBillingTransport.unreachable(), storage: storage)
        await before.recordAccountReset() // reset() without AppReferBilling.logOut()
        XCTAssertEqual(storage.resetUser, "user_a")

        // Relaunch: the in-process epoch starts again, configure runs (gate open), and
        // Billing still serves user_a.
        let transport = MockBillingTransport { request in
            let user = request.jsonBody?["appUserId"] as? String ?? "user_a"
            return (Data(BillingFixtures.customerJSON(appUserId: user).utf8), 200)
        }
        let engine = env.engine(transport: transport, appUserId: "user_a", storage: env.storage())
        await engine.setAttributes(["$email": "a@example.com", "$idfv": "IDFV-1"])
        _ = await engine.customerInfo(policy: .fetchCurrent)
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(), counter: FinishCounter()))
        _ = await engine.customerInfo(policy: .fetchCurrent)
        let customers = billingBodies(transport, "/api/billing/v1/customers")
        let purchases = billingBodies(transport, "/api/billing/v1/purchases")
        XCTAssertEqual(customers.count, 1, "no re-link for the previous account")
        XCTAssertEqual(purchases.count, 1)
        XCTAssertTrue((customers + purchases).allSatisfy { $0["appreferId"] == nil })
        XCTAssertEqual(customers[0]["attributes"] as? [String: String], ["$email": "a@example.com"])
        XCTAssertEqual(env.storage().resetUser, "user_a", "configure with the same id keeps the marker")

        // An explicit logIn, even with the same id, says who the user is now.
        _ = try await engine.logIn("user_a")
        XCTAssertNil(env.storage().resetUser)
        _ = await engine.process(BillingFixtures.update(BillingFixtures.transaction(id: "2000000000000007"), counter: FinishCounter()))
        let linked = billingBodies(transport, "/api/billing/v1/customers")
        XCTAssertEqual(linked.count, 2, "linked once")
        XCTAssertEqual(linked.last?["appreferId"] as? String, "device-abc")
        XCTAssertEqual(billingBodies(transport, "/api/billing/v1/purchases").last?["appreferId"] as? String, "device-abc")
    }

    func testResetMarkerForAnAnonymousUserEndsOnLogOut() async throws {
        let storage = env.storage()
        let anonymous = try XCTUnwrap(storage.anonymousId())
        storage.recordAccountReset()
        XCTAssertEqual(storage.resetUser, anonymous)

        let transport = MockBillingTransport { request in
            let user = request.jsonBody?["appUserId"] as? String ?? anonymous
            return (Data(BillingFixtures.customerJSON(appUserId: user).utf8), 200)
        }
        let engine = env.engine(transport: transport, storage: env.storage())
        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertNil(billingBodies(transport, "/api/billing/v1/customers").last?["appreferId"])
        _ = await engine.logOut()
        XCTAssertNil(env.storage().resetUser)
        let customers = billingBodies(transport, "/api/billing/v1/customers")
        XCTAssertNotEqual(customers.last?["appUserId"] as? String, anonymous)
        XCTAssertEqual(customers.last?["appreferId"] as? String, "device-abc")
    }

    func testADifferentBillingUserClearsTheMarker() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        storage.recordAccountReset()
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_b"))
        // Relaunch configured for another user.
        let engine = env.engine(transport: transport, appUserId: "user_b", storage: env.storage())
        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertNil(env.storage().resetUser)
        XCTAssertEqual(billingBodies(transport, "/api/billing/v1/customers").last?["appreferId"] as? String, "device-abc")
    }

    func testIdentifySendsLinkFalseWhileTheMarkerHolds() async throws {
        let storage = env.storage()
        let anonymous = try XCTUnwrap(storage.anonymousId())
        // logIn reached the device but not the server; then reset() without logOut.
        storage.addPendingIdentify(anonymousId: anonymous, appUserId: "user_a")
        storage.loggedInAppUserId = "user_a"
        storage.recordAccountReset()
        let transport = MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_a"))
        let engine = env.engine(transport: transport, appUserId: "user_a", storage: env.storage(), linkAllowed: { true })
        _ = await engine.customerInfo(policy: .fetchCurrent)
        let identify = try XCTUnwrap(billingBodies(transport, "/api/billing/v1/identify").last)
        XCTAssertEqual(identify["link"] as? Bool, false)
    }

    func testResetWithoutABillingUserStoresNothing() {
        let storage = env.storage()
        storage.recordAccountReset()
        XCTAssertNil(storage.resetUser)
        XCTAssertFalse(storage.hasAnonymousId, "never mints an id")
    }

    // MARK: - Round 2 A: never mark the anonymous id logOut() just minted; no late writes

    func testLogOutThenResetDoesNotMarkTheFreshAnonymousId() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let transport = MockBillingTransport { request in
            let user = request.jsonBody?["appUserId"] as? String ?? "x"
            return (Data(BillingFixtures.customerJSON(appUserId: user).utf8), 200)
        }
        let engine = env.engine(transport: transport, storage: storage)
        _ = await engine.logOut()
        let fresh = try XCTUnwrap(storage.storedCurrentAppUserId)
        XCTAssertTrue(BillingStorage.isAnonymous(fresh))
        await engine.recordAccountReset(resetTicket: engine.identityChanges.take())
        XCTAssertNil(storage.resetUser, "the next account's fresh anonymous id is not the previous account")
        _ = await engine.customerInfo(policy: .fetchCurrent)
        XCTAssertEqual(billingBodies(transport, "/api/billing/v1/customers").last?["appreferId"] as? String, "device-abc")

        // After a logIn, a later reset marks that user as before.
        _ = try await engine.logIn("user_c")
        await engine.recordAccountReset(resetTicket: engine.identityChanges.take())
        XCTAssertEqual(storage.resetUser, "user_c")
    }

    func testResetMarkerWriteThatLandsAfterALogInIsSkipped() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let engine = env.engine(transport: MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_b")), storage: storage)
        // reset() starts (snapshot), the app calls logIn(user_b) without awaiting reset().
        let resetTicket = engine.identityChanges.take()
        _ = try await engine.logIn("user_b")
        await engine.recordAccountReset(resetTicket: resetTicket)
        XCTAssertNil(storage.resetUser, "the late write must not mark the next account")
    }

    func testLogInBeforeResetIsStillMarked() async throws {
        let storage = env.storage()
        let engine = env.engine(transport: MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_a")), storage: storage)
        _ = try await engine.logIn("user_a")
        let resetTicket = engine.identityChanges.take() // reset() called after logIn
        await engine.recordAccountReset(resetTicket: resetTicket)
        XCTAssertEqual(storage.resetUser, "user_a")
    }

    // MARK: - Round 2 B: the Billing marker lives with the Keychain identity; fail closed

    func testBillingResetMarkerIsKeptInTheSecureStoreAndSurvivesAReinstall() throws {
        let storage = env.storage()
        let anonymous = try XCTUnwrap(storage.anonymousId())
        storage.recordAccountReset()
        XCTAssertEqual(env.secure.read("apprefer_billing_reset_user").value, anonymous)
        XCTAssertNil(env.defaults.object(forKey: "apprefer_billing_reset_user"))

        // Reinstall: UserDefaults gone, Keychain (anonymous id, marker) kept.
        let reinstalled = BillingStorage(secure: env.secure, defaults: UserDefaults(suiteName: UUID().uuidString)!, directory: env.directory)
        XCTAssertEqual(reinstalled.storedCurrentAppUserId, anonymous)
        XCTAssertTrue(reinstalled.resetMarkerHolds(for: anonymous))
    }

    func testBillingResetMarkerMovesFromUserDefaultsAndFailsClosed() {
        env.defaults.set("user_a", forKey: "apprefer_billing_reset_user")
        let storage = env.storage()
        XCTAssertEqual(storage.resetUser, "user_a")
        XCTAssertEqual(env.secure.read("apprefer_billing_reset_user").value, "user_a")
        XCTAssertNil(env.defaults.object(forKey: "apprefer_billing_reset_user"))

        // Keychain locked: the marker can't be ruled out, so the gate stays closed.
        env.secure.isLocked = true
        XCTAssertTrue(storage.resetMarkerHolds(for: "user_b"))
        env.secure.isLocked = false
        XCTAssertFalse(storage.resetMarkerHolds(for: "user_b"))
        XCTAssertNil(storage.resetUser)
    }

    func testSupportClearedFlagsFailClosedWhenTheKeychainCantBeRead() {
        let keychain = FakeDeviceIdKeychain()
        let storage = attributionStorage(keychain: keychain)
        XCTAssertFalse(storage.supportIdentityCleared)
        keychain.locked = true
        XCTAssertTrue(storage.supportIdentityCleared, "locked reads as cleared")

        XCTAssertTrue(SupportAPI.sessionMintedWhileCleared(.unavailable(errSecInteractionNotAllowed)))
        XCTAssertTrue(SupportAPI.sessionMintedWhileCleared(.failed(errSecIO)))
        UserDefaults.standard.removeObject(forKey: SupportAPI.clearedSessionKey)
        XCTAssertFalse(SupportAPI.sessionMintedWhileCleared(.failed(errSecMissingEntitlement)), "no Keychain at all: UserDefaults is the store")
        XCTAssertFalse(SupportAPI.sessionMintedWhileCleared(.notFound))
    }

    // MARK: - Round 3 E1: only an applied logIn/logOut called after reset() cancels its marker

    func testThrowingLogInDoesNotCancelTheResetMarker() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let engine = env.engine(transport: MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_a")), storage: storage)
        let resetTicket = engine.identityChanges.take()
        do { _ = try await engine.logIn(""); XCTFail("expected invalidAppUserId") } catch {}
        do { _ = try await engine.logIn("has space"); XCTFail("expected invalidAppUserId") } catch {}
        await engine.recordAccountReset(resetTicket: resetTicket)
        XCTAssertEqual(storage.resetUser, "user_a", "a logIn that threw changed nothing")
    }

    func testLogInCalledBeforeResetButAppliedAfterItStartedIsStillMarked() async throws {
        let storage = env.storage()
        let engine = env.engine(transport: MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_a")), storage: storage)
        let logInTicket = engine.identityChanges.take() // AppReferBilling.logIn("user_a") called
        let resetTicket = engine.identityChanges.take() // then AppRefer.reset() called
        _ = try await engine.logIn("user_a", ticket: logInTicket)
        await engine.recordAccountReset(resetTicket: resetTicket)
        XCTAssertEqual(storage.resetUser, "user_a")
    }

    // MARK: - Round 3 E2: configure while reset() runs only skips the marker for another user

    func testConfigureDuringResetSkipsOnlyForADifferentUser() async throws {
        XCTAssertFalse(AppReferBilling.configuredForAnotherUser(configured: nil, storedAtReset: "user_a"))
        XCTAssertFalse(AppReferBilling.configuredForAnotherUser(configured: "user_a", storedAtReset: "user_a"))
        XCTAssertTrue(AppReferBilling.configuredForAnotherUser(configured: "user_b", storedAtReset: "user_a"))
        XCTAssertTrue(AppReferBilling.configuredForAnotherUser(configured: "user_b", storedAtReset: nil))

        // An engine configured meanwhile without appUserId resumes user_a, who is marked.
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let engine = env.engine(transport: MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "user_a")), storage: storage)
        XCTAssertNil(engine.configuredAppUserId)
        await engine.recordAccountReset(resetTicket: 0)
        XCTAssertEqual(storage.resetUser, "user_a")

        // A logIn on that engine (necessarily after reset() was called) cancels the write.
        _ = try await engine.logIn("user_b")
        await engine.recordAccountReset(resetTicket: 0)
        XCTAssertNil(storage.resetUser)
    }

    // MARK: - Round 3 E4: the logOut exemption is used once

    func testSecondResetMarksTheUserLogOutMinted() async throws {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_a"
        let engine = env.engine(transport: MockBillingTransport.ok(BillingFixtures.customerJSON(appUserId: "x")), storage: storage)
        _ = await engine.logOut()
        let fresh = try XCTUnwrap(storage.storedCurrentAppUserId)
        await engine.recordAccountReset(resetTicket: engine.identityChanges.take())
        XCTAssertNil(storage.resetUser)
        // Another reset while that anonymous user is still current: marked this time.
        await engine.recordAccountReset(resetTicket: engine.identityChanges.take())
        XCTAssertEqual(storage.resetUser, fresh)
    }

    // MARK: - Round 3 E5: no Support session on an unreadable store; never delete what wasn't retired

    func testNoSupportSessionWhileTheClearedFlagCantBeRead() async throws {
        let flagKeychain = FakeDeviceIdKeychain()
        let tokens = FakeDeviceIdKeychain()
        _ = tokens.save(key: "apprefer_support_session", value: "ars_real")
        let userStorage = attributionStorage(keychain: flagKeychain)
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage, tokenKeychain: tokens)
        await api.configure(apiKey: "pk_test")
        await api.revokePending(using: "pk_test")
        SupportRecorder093.clear()
        flagKeychain.locked = true // before first unlock
        do { _ = try await api.conversations(); XCTFail("expected a retryable error") } catch let error as AppReferSupportError {
            XCTAssertEqual(error.status, 0)
        }
        XCTAssertTrue(SupportRecorder093.calls.isEmpty, "no session minted or adopted on a guess")
        XCTAssertEqual(tokens.value("apprefer_support_session"), "ars_real")
        XCTAssertNil(tokens.value(SupportAPI.clearedSessionKey))

        // Unlocked: the real session is used as before, never retired.
        flagKeychain.locked = false
        _ = try await api.conversations()
        XCTAssertEqual(SupportRecorder093.calls.last?.session, "ars_real")
        XCTAssertEqual(tokens.value("apprefer_support_session"), "ars_real")
        await api.reset()
        await api.revokePending(using: "pk_test")
    }

    func testClearedMarkerIsNotRecordedForATokenThatCouldNotBeSaved() async throws {
        let tokens = FakeDeviceIdKeychain()
        tokens.failSaves = true
        let userStorage = attributionStorage()
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage, tokenKeychain: tokens)
        await api.configure(apiKey: "pk_test")
        await api.revokePending(using: "pk_test")
        UserDefaults.standard.removeObject(forKey: SupportAPI.clearedSessionKey)
        SupportRecorder093.clear()
        await api.clearIdentity()
        let cleared = try XCTUnwrap(SupportRecorder093.sessionPosts().last)
        XCTAssertNil(cleared.session)
        XCTAssertNil(tokens.value(SupportAPI.clearedSessionKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SupportAPI.clearedSessionKey), "not recorded for an unsaved token")
        XCTAssertEqual(SupportAPI.sessionClearedMarkerState(keychain: tokens), .notCleared)

        // In this process the unsaved cleared session is still never handed to another user.
        _ = try await api.conversations()
        let clearedSession = try XCTUnwrap(SupportRecorder093.calls.last?.session)
        userStorage.setUserId("acct_B")
        _ = try await api.conversations()
        let forB = try XCTUnwrap(SupportRecorder093.sessionPosts().last)
        XCTAssertNil(forB.session)
        XCTAssertEqual(forB.body["appUserId"] as? String, "acct_B")
        XCTAssertFalse(SupportRecorder093.calls.contains { $0.session == clearedSession && $0.body["appUserId"] as? String == "acct_B" })
        await api.reset()
        await api.revokePending(using: "pk_test")
    }

    func testALockedTokenStoreNeverLosesTheStoredTokenAndARetiredOneIsNotReused() async throws {
        let tokens = FakeDeviceIdKeychain()
        let userStorage = attributionStorage()
        userStorage.setUserId("acct_A")
        let api = supportAPI(userStorage, tokenKeychain: tokens)
        await api.configure(apiKey: "pk_test")
        await api.revokePending(using: "pk_test")
        _ = try await api.conversations()
        let session = try XCTUnwrap(tokens.value("apprefer_support_session"))

        // reset() while the Keychain is locked: the stored token can't be read, so it isn't
        // deleted (its revocation is queued from memory).
        SupportRecorder093.failDeletes = true
        tokens.locked = true
        await api.reset()
        tokens.locked = false
        XCTAssertEqual(tokens.value("apprefer_support_session"), session)

        // Unlocked: the retired token is never reused for the next account.
        userStorage.setUserId("acct_B")
        SupportRecorder093.clear()
        SupportRecorder093.failDeletes = true
        _ = try await api.conversations()
        XCTAssertFalse(SupportRecorder093.calls.contains { $0.method != "DELETE" && $0.session == session })
        XCTAssertNil(SupportRecorder093.sessionPosts().last?.session)
        XCTAssertNotEqual(tokens.value("apprefer_support_session"), session)
        SupportRecorder093.failDeletes = false
        await api.reset()
        await api.revokePending(using: "pk_test")
    }
}
