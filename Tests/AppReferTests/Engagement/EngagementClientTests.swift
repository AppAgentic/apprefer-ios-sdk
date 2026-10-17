import XCTest
@testable import AppRefer

/// Lifecycle engagement client: registration, credential storage, serialized identity
/// changes, preferences, receipts and graceful degradation.
final class EngagementClientTests: XCTestCase {
    private var server: FakeEngagementServer!
    private var keychain: FakeDeviceIdKeychain!
    private var defaults: UserDefaults!
    private let key = "pk_live_sparkly000000000000000001"

    override func setUp() {
        server = FakeEngagementServer()
        keychain = FakeDeviceIdKeychain()
        defaults = UserDefaults(suiteName: "eng-\(UUID().uuidString)")!
    }

    private func client(now: @escaping @Sendable () -> Date = { Date() }, permission: AppReferNotificationPermission = .granted) -> EngagementClient {
        EngagementClient(baseURL: "https://apprefer.test", session: server.session(), keychain: keychain, defaults: defaults, now: now,
                         deviceState: { EngagementDeviceState(timezone: "Europe/London", locale: "en-GB", collectionEnabled: true, permission: permission) },
                         pushEnvironment: { "sandbox" }, deviceId: { "dev-0000-0001" })
    }

    private func installId(_ status: AppReferEngagementStatus) -> String? {
        if case .active(let id) = status { return id }
        return nil
    }

    private func payload(_ c: EngagementClient, epoch: Int? = nil, mid: String = "sparkly_live_j_x_nudge") async -> AppReferEngagementPayload {
        let snap = c.snapshot.get()!
        let object = PayloadFixture.object(["iid": snap.installId, "epoch": epoch ?? snap.accountEpoch!, "mid": mid])
        guard case .valid(let p) = AppReferEngagementPayload.parse(object: object) else { fatalError() }
        return p
    }

    // MARK: Registration and storage

    func testRegistersOnceAndKeepsOnlyTheSecretInTheKeychain() async throws {
        let c = client()
        let status = await c.start(apiKey: key, explicit: true, options: .init(notificationServiceExtension: true))
        let id = try XCTUnwrap(installId(status))
        XCTAssertEqual(server.requests("POST", "/api/engagement/v1/installs").count, 1)
        let registration = try XCTUnwrap(server.requests("POST", "/api/engagement/v1/installs").first)
        XCTAssertEqual(registration.body["platform"] as? String, "ios")
        XCTAssertEqual(registration.body["deviceId"] as? String, "dev-0000-0001")
        XCTAssertNil(registration.headers["X-AppRefer-Install"])
        let secret = try XCTUnwrap(server.install(id)?.secret)
        // Secret only in the Keychain, never in UserDefaults.
        XCTAssertTrue(keychain.value("apprefer_engagement_install_\(EngagementClient.slot(for: key))")?.contains(secret) == true)
        let plist = defaults.dictionaryRepresentation().description
        XCTAssertFalse(plist.contains(secret))
        // Device state sent once, with capabilities and no prompt.
        let patch = try XCTUnwrap(server.install(id)?.patches.last)
        XCTAssertEqual(patch["notificationPermission"] as? String, "granted")
        XCTAssertEqual(patch["timezone"] as? String, "Europe/London")
        XCTAssertEqual((patch["capabilities"] as? [String: Any])?["images"] as? Bool, true)
        XCTAssertNil(patch["pushToken"])

        // A new process with the same Keychain reuses the install: no second registration.
        let again = client()
        let _aw1 = await again.start(apiKey: key, explicit: true, options: .init())
        XCTAssertEqual(installId(_aw1), id)
        XCTAssertEqual(server.requests("POST", "/api/engagement/v1/installs").count, 1)
    }

    func testPushTokenUsesTheSigningEnvironmentAndUnchangedStateIsNotResent() async throws {
        let c = client()
        let _aw2 = await c.start(apiKey: key, explicit: true, options: .init())
        let id = try XCTUnwrap(installId(_aw2))
        await c.setPushToken("ab".repeated(32))
        await c.setPushToken("ab".repeated(32))
        let patches = server.install(id)!.patches
        XCTAssertEqual(patches.count, 2, "initial state, then the token once")
        XCTAssertEqual(patches.last?["pushToken"] as? String, "ab".repeated(32))
        XCTAssertEqual(patches.last?["pushEnvironment"] as? String, "sandbox")
    }

    func testDisabledOnTheServerDegradesQuietly() async throws {
        server.disabled = true
        let c = client()
        let _aw3 = await c.start(apiKey: key, explicit: true, options: .init())
        XCTAssertEqual(_aw3, .disabled)
        XCTAssertNil(keychain.value("apprefer_engagement_install_\(EngagementClient.slot(for: key))"))
        XCTAssertNil(c.snapshot.get())
        // Within six hours nothing is asked again, and calls fail softly.
        server.disabled = false
        let _aw4 = await client().start(apiKey: key, explicit: true, options: .init())
        XCTAssertEqual(_aw4, .disabled)
        XCTAssertEqual(server.requests().count, 1)
        do { _ = try await c.preferences(); XCTFail() } catch { XCTAssertEqual(error as? AppReferEngagementError, .notStarted) }
        await c.logout() // no throw, no request
        XCTAssertEqual(server.requests().count, 1)
    }

    func testDisabledIsRetriedAfterSixHours() async throws {
        server.disabled = true
        let later = Date().addingTimeInterval(6 * 3600 + 1)
        let _aw6 = await client().start(apiKey: key, explicit: true, options: .init())
        XCTAssertEqual(_aw6, .disabled)
        server.disabled = false
        let _aw7 = await client(now: { later }).start(apiKey: key, explicit: true, options: .init())
        XCTAssertNotNil(installId(_aw7))
    }

    func testOfflineAndLockedKeychainArePendingAndRetried() async throws {
        keychain.locked = true
        let c = client()
        let _aw8 = await c.start(apiKey: key, explicit: true, options: .init())
        XCTAssertEqual(_aw8, .pending)
        XCTAssertTrue(server.requests().isEmpty, "never a second install while the Keychain is locked")
        keychain.locked = false
        server.offline = true
        await c.becameActive()
        let _aw9 = await c.status
        XCTAssertEqual(_aw9, .pending)
        server.offline = false
        await c.becameActive()
        let _aw10 = await c.status
        XCTAssertNotNil(installId(_aw10))
        XCTAssertEqual(server.installCount, 1)
    }

    func testAnInstallErasedOnTheServerIsReplacedOnce() async throws {
        let c = client()
        let _aw11 = await c.start(apiKey: key, explicit: true, options: .init())
        let first = try XCTUnwrap(installId(_aw11))
        server.forget(first)
        let _aw12 = await client().start(apiKey: key, explicit: true, options: .init())
        let second = try XCTUnwrap(installId(_aw12))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(server.requests("POST", "/api/engagement/v1/installs").count, 2)
    }

    func testAKeychainThatCannotSaveNeverLeavesAnInstallBehind() async {
        keychain.failSaves = true
        keychain.failAdds = true
        let _aw13 = await client().start(apiKey: key, explicit: true, options: .init())
        XCTAssertEqual(_aw13, .pending)
        XCTAssertEqual(server.installCount, 0, "the minted install was deleted again")
    }

    func testConfigurationSwitchUsesItsOwnSlot() async throws {
        let c = client()
        let _aw14 = await c.start(apiKey: key, explicit: false, options: .init())
        let a = try XCTUnwrap(installId(_aw14))
        let other = "pk_test_sparkly000000000000000001"
        await c.configurationChanged(apiKey: other)
        let _aw15 = await c.status
        let b = try XCTUnwrap(installId(_aw15))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(server.install(b)?.key, other)
        XCTAssertNotNil(keychain.value("apprefer_engagement_install_\(EngagementClient.slot(for: key))"), "the other app's credential is untouched")
        // An explicitly keyed engagement doesn't follow configure.
        let pinned = client()
        _ = await pinned.start(apiKey: key, explicit: true, options: .init())
        await pinned.configurationChanged(apiKey: other)
        let _aw16 = await pinned.status
        XCTAssertEqual(installId(_aw16), a)
    }

    // MARK: Identity

    func testIdentifyLogoutAndSignInAgainInOrderWhileCallsAreInFlight() async throws {
        let c = client()
        let _aw17 = await c.start(apiKey: key, explicit: true, options: .init())
        let id = try XCTUnwrap(installId(_aw17))
        server.delays["POST /api/engagement/v1/installs/me/account"] = 0.3
        async let signInA: Void = try c.identify(assertion: "ok:user-a")
        try await Task.sleep(nanoseconds: 50_000_000)
        async let out: Void = c.logout()
        try await Task.sleep(nanoseconds: 20_000_000)
        async let signInB: Void = try c.identify(assertion: "ok:user-b")
        _ = try await (signInA, out, signInB)
        let calls = server.requests().filter { $0.path.hasSuffix("/account") || $0.path.hasSuffix("/logout") }.map { $0.path.hasSuffix("/logout") ? "logout" : ($0.body["assertion"] as? String ?? "") }
        XCTAssertEqual(calls, ["ok:user-a", "logout", "ok:user-b"], "the server sees them in call order")
        XCTAssertEqual(server.install(id)?.account, "user-b")
        let state = await c.stateForTesting()
        XCTAssertEqual(state.epoch, server.install(id)?.epoch)
        XCTAssertFalse(state.pendingLogout)
    }

    func testLogoutDuringRegistrationStillLogsOutAfterIt() async throws {
        server.delays["POST /api/engagement/v1/installs"] = 0.3
        let c = client()
        async let started = c.start(apiKey: key, explicit: true, options: .init())
        try await Task.sleep(nanoseconds: 50_000_000)
        await c.logout()
        let _aw18 = await started
        let id = try XCTUnwrap(installId(_aw18))
        XCTAssertEqual(server.requests("POST", "/api/engagement/v1/installs/me/logout").count, 1)
        XCTAssertEqual(server.install(id)?.epoch, 1)
        let state = await c.stateForTesting()
        XCTAssertEqual(state.epoch, 1)
    }

    func testOfflineLogoutIsSentBeforeAnythingElseNextTime() async throws {
        let c = client()
        let _aw19 = await c.start(apiKey: key, explicit: true, options: .init())
        let id = try XCTUnwrap(installId(_aw19))
        try await c.identify(assertion: "ok:user-a")
        server.offline = true
        await c.logout()
        let pending = await c.stateForTesting()
        XCTAssertTrue(pending.pendingLogout)
        XCTAssertNil(pending.epoch, "nothing matches until the server confirms")
        XCTAssertNil(c.snapshot.get()?.accountEpoch)
        server.offline = false
        _ = await client().start(apiKey: key, explicit: true, options: .init())
        XCTAssertNil(server.install(id)?.account)
        let order = server.requests().map(\.path).filter { $0.hasSuffix("/logout") || $0.hasSuffix("/installs/me") }
        XCTAssertEqual(order.last(where: { $0.hasSuffix("/logout") }) != nil, true)
        XCTAssertEqual(order.dropFirst(order.firstIndex(where: { $0.hasSuffix("/logout") }) ?? 0).first, "/api/engagement/v1/installs/me/logout")
    }

    func testResetBeforeStartIsAppliedWhenEngagementStarts() async throws {
        let c = client()
        let _aw20 = await c.start(apiKey: key, explicit: true, options: .init())
        let id = try XCTUnwrap(installId(_aw20))
        try await c.identify(assertion: "ok:user-a")
        // Next launch: reset() runs before the app starts engagement.
        let next = client()
        await next.logout()
        XCTAssertEqual(server.install(id)?.account, "user-a", "nothing sent before start")
        _ = await next.start(apiKey: key, explicit: true, options: .init())
        XCTAssertNil(server.install(id)?.account)
    }

    func testInvalidAssertionLeavesTheIdentityAndReportsIt() async throws {
        let c = client()
        _ = await c.start(apiKey: key, explicit: true, options: .init())
        do { try await c.identify(assertion: "forged"); XCTFail() } catch { XCTAssertEqual(error as? AppReferEngagementError, .invalidAssertion) }
        let state = await c.stateForTesting()
        XCTAssertEqual(state.epoch, 0, "re-read from the server")
        do { try await client().identify(assertion: "ok:x"); XCTFail() } catch { XCTAssertEqual(error as? AppReferEngagementError, .notStarted) }
    }

    func testABackendSideAccountChangeMovesTheIdentitySerial() async throws {
        let c = client()
        let _aw23 = await c.start(apiKey: key, explicit: true, options: .init())
        let id = try XCTUnwrap(installId(_aw23))
        let before = c.snapshot.get()!.serial
        server.set(id) { $0.epoch = 5; $0.account = "bound-by-backend" }
        await c.setPushToken("cd".repeated(32))
        XCTAssertEqual(c.snapshot.get()?.accountEpoch, 5)
        XCTAssertGreaterThan(c.snapshot.get()!.serial, before)
    }

    // MARK: Preferences

    func testPreferencesBelongToTheIdentity() async throws {
        let c = client()
        let _aw24 = await c.start(apiKey: key, explicit: true, options: .init())
        let id = try XCTUnwrap(installId(_aw24))
        let initial = try await c.preferences()
        XCTAssertEqual(initial, AppReferEngagementPreferences(marketing: false, reminders: false, service: true))
        try await c.identify(assertion: "ok:user-a")
        let set = try await c.setPreferences(["marketing": true])
        XCTAssertTrue(set.marketing)
        await c.logout()
        XCTAssertEqual(server.install(id)?.prefs["marketing"], false, "A's choice doesn't carry over")
        do { _ = try await c.setPreferences([:]); XCTFail() } catch {}
    }

    func testPreferencesRefusedMidAccountChange() async throws {
        let c = client()
        _ = await c.start(apiKey: key, explicit: true, options: .init())
        server.offline = true
        await c.logout()
        server.offline = false
        do { _ = try await c.setPreferences(["marketing": true]); XCTFail() } catch { XCTAssertEqual(error as? AppReferEngagementError, .identityChanged) }
    }

    // MARK: Receipts

    func testReceiptsAreSentWithProofOnlyForTheCurrentIdentity() async throws {
        let c = client()
        _ = await c.start(apiKey: key, explicit: true, options: .init())
        let p = await payload(c)
        await c.queueReceipt(kind: "opened", payload: p, actionId: nil, at: Date())
        let sent = try XCTUnwrap(server.requests("POST", "/api/engagement/v1/installs/me/receipts").last)
        let item = try XCTUnwrap((sent.body["receipts"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["messageId"] as? String, p.messageId)
        XCTAssertEqual(item["token"] as? String, p.receiptToken)
        XCTAssertEqual(item["kind"] as? String, "opened")
        let queued = await c.pendingReceiptCount
        XCTAssertEqual(queued, 0)
        // A payload for another epoch is never queued.
        let other = await payload(c, epoch: 9, mid: "sparkly_live_j_y_nudge")
        await c.queueReceipt(kind: "opened", payload: other, actionId: nil, at: Date())
        XCTAssertEqual(server.requests("POST", "/api/engagement/v1/installs/me/receipts").count, 1)
    }

    func testOfflineReceiptsWaitAndAreDroppedOnAccountChange() async throws {
        let c = client()
        _ = await c.start(apiKey: key, explicit: true, options: .init())
        let p = await payload(c)
        server.offline = true
        await c.queueReceipt(kind: "opened", payload: p, actionId: nil, at: Date())
        await c.queueReceipt(kind: "opened", payload: p, actionId: nil, at: Date()) // de-duplicated
        var queued = await c.pendingReceiptCount
        XCTAssertEqual(queued, 1)
        server.offline = false
        await c.becameActive()
        queued = await c.pendingReceiptCount
        XCTAssertEqual(queued, 0)

        server.offline = true
        let q = await payload(c, mid: "sparkly_live_j_z_nudge")
        await c.queueReceipt(kind: "opened", payload: q, actionId: nil, at: Date())
        server.offline = false
        try await c.identify(assertion: "ok:user-b")
        queued = await c.pendingReceiptCount
        XCTAssertEqual(queued, 0, "never sent under the next account")
        let sent = server.requests("POST", "/api/engagement/v1/installs/me/receipts").filter { !$0.path.isEmpty && server.offline == false }
            .flatMap { ($0.body["receipts"] as? [[String: Any]]) ?? [] }
        XCTAssertEqual(sent.filter { $0["messageId"] as? String == q.messageId }.count, 1, "only the offline attempt, before the sign-in")
    }

    func testRejectedReceiptsAreNotRetried() async throws {
        server.receiptResults = { _ in "rejected" }
        let c = client()
        _ = await c.start(apiKey: key, explicit: true, options: .init())
        await c.queueReceipt(kind: "dismissed", payload: await payload(c), actionId: nil, at: Date())
        let queued = await c.pendingReceiptCount
        XCTAssertEqual(queued, 0)
    }

    func testAppGroupMarkersFromTheExtensionAreReported() async throws {
        let group = "group.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: group)?.removePersistentDomain(forName: group) }
        let c = client()
        let _aw27 = await c.start(apiKey: key, explicit: true, options: .init(appGroup: group))
        let id = try XCTUnwrap(installId(_aw27))
        let shared = AppReferNotificationSharedState(appGroup: group)
        XCTAssertEqual(shared.identity(), .init(installId: id, accountEpoch: 0))
        shared.appendReceived(.init(messageId: "sparkly_live_j_r_nudge", installId: id, accountEpoch: 0, receiptToken: PayloadFixture.token, receivedAt: Date()))
        shared.appendReceived(.init(messageId: "sparkly_live_j_s_nudge", installId: id, accountEpoch: 7, receiptToken: PayloadFixture.token, receivedAt: Date()))
        await c.becameActive()
        let sent = server.requests("POST", "/api/engagement/v1/installs/me/receipts").flatMap { ($0.body["receipts"] as? [[String: Any]]) ?? [] }
        XCTAssertEqual(sent.map { $0["messageId"] as? String }, ["sparkly_live_j_r_nudge"])
        XCTAssertEqual(sent.first?["kind"] as? String, "received")
        // During a sign-out the extension sees no matching identity.
        server.offline = true
        await c.logout()
        XCTAssertEqual(shared.identity(), .init(installId: id, accountEpoch: nil))
    }

    func testDeleteInstallForgetsItAndRetriesWhenOffline() async throws {
        let c = client()
        let _aw28 = await c.start(apiKey: key, explicit: true, options: .init())
        let id = try XCTUnwrap(installId(_aw28))
        server.offline = true
        await c.deleteInstall()
        let _aw29 = await c.status
        XCTAssertEqual(_aw29, .pending)
        XCTAssertNil(c.snapshot.get())
        server.offline = false
        let _aw30 = await client().start(apiKey: key, explicit: true, options: .init())
        let fresh = try XCTUnwrap(installId(_aw30))
        XCTAssertNil(server.install(id), "the pending delete went first")
        XCTAssertNotEqual(fresh, id)
    }
}

enum PayloadFixture {
    static let token = "er1." + String(repeating: "A", count: 43)
    static func object(_ overrides: [String: Any?] = [:]) -> [String: Any] {
        var o: [String: Any] = [
            "type": "engagement", "v": 1, "mid": "sparkly_live_finish-setup_abc_nudge", "purpose": "reminders",
            "exp": (Date().timeIntervalSince1970 + 3600) * 1000, "epoch": 0, "iid": "ei_" + String(repeating: "a", count: 26),
            "dest": "/setup", "ck": "setup", "title": "Finish Garden", "body": "One step left.",
            "actions": [["id": "start", "kind": "start", "dest": "/setup/next"], ["id": "later", "kind": "snooze", "min": 60]],
            "rt": token,
        ]
        for (k, v) in overrides { if let v { o[k] = v } else { o.removeValue(forKey: k) } }
        return o
    }
}

extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}
