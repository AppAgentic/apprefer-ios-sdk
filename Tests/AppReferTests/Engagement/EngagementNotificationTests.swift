import XCTest
@testable import AppRefer

private actor FakeSystem: EngagementNotificationSystem {
    var snoozes: [(identifier: String, category: String?, after: TimeInterval, userInfo: [String: Any])] = []
    var categories: [EngagementCategory] = []
    /// What the notification center holds (pending or delivered), by identifier.
    var scheduled: Set<String> = ["host.reminder", "apprefer.support.local"]
    /// When set, the next add waits here (an in-flight `UNUserNotificationCenter.add`).
    private var gate: CheckedContinuation<Void, Never>?
    var holdNextAdd = false
    private(set) var addStarted = false
    func scheduleSnooze(identifier: String, title: String, subtitle: String?, body: String, userInfo: [String: Any],
                        category: String?, thread: String?, after seconds: TimeInterval) async -> Bool {
        snoozes.append((identifier, category, seconds, userInfo))
        if holdNextAdd {
            holdNextAdd = false
            addStarted = true
            await withCheckedContinuation { gate = $0 }
        }
        scheduled.insert(identifier)
        return true
    }
    func releaseAdd() { gate?.resume(); gate = nil }
    func hold() { holdNextAdd = true }
    func removeSnoozes(identifiers: [String]?) async {
        scheduled = scheduled.filter { !($0.hasPrefix(snoozePrefix) && (identifiers?.contains($0) ?? true)) }
    }
    func held() -> Set<String> { scheduled }
    func registerCategories(_ categories: [EngagementCategory]) async { self.categories = categories }
    func snoozeCount() -> Int { snoozes.count }
    func lastSnooze() -> (identifier: String, category: String?, after: TimeInterval, userInfo: [String: Any])? { snoozes.last }
}

private actor ReceiptLog {
    var items: [(String, String, String?)] = []
    func add(_ kind: String, _ mid: String, _ action: String?) { items.append((kind, mid, action)) }
    func kinds() -> [String] { items.map(\.0) }
}

@MainActor
final class EngagementNotificationTests: XCTestCase {
    private let iid = "ei_" + String(repeating: "a", count: 26)
    private var box: EngagementSnapshotBox!
    private var system: FakeSystem!
    private var receipts: ReceiptLog!
    private var events: [AppReferEngagementNotificationEvent] = []
    private var layer: EngagementNotifications!

    override func setUp() async throws {
        box = EngagementSnapshotBox()
        box.set(EngagementSnapshot(slot: "s", installId: iid, accountEpoch: 2, serial: 1, header: "h", trackedEvents: nil))
        system = FakeSystem()
        receipts = ReceiptLog()
        let log = receipts!
        layer = EngagementNotifications(snapshot: box, receipts: { kind, p, action, _ in await log.add(kind, p.messageId, action) },
                                        system: system, defaults: UserDefaults(suiteName: "n-\(UUID().uuidString)")!)
        events = []
    }

    private func info(_ overrides: [String: Any?] = [:]) -> [AnyHashable: Any] {
        ["apprefer": PayloadFixture.object(["epoch": 2, "iid": iid].merging(overrides) { $1 })]
    }
    private func respond(_ action: String, _ userInfo: [AnyHashable: Any]? = nil, category: String = "apprefer.eng.start.snooze") async -> Bool {
        await layer.handleResponse(userInfo: userInfo ?? info(), actionIdentifier: action, categoryIdentifier: category)
    }
    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

    func testSupportAndForeignNotificationsAreLeftAlone() async {
        let support: [AnyHashable: Any] = ["apprefer": ["type": "support_reply", "conversationId": "cv_1"]]
        XCTAssertEqual(layer.check(support), .notEngagement)
        let handled = await layer.handleResponse(userInfo: support, actionIdentifier: EngagementNotifications.defaultAction, categoryIdentifier: "")
        XCTAssertFalse(handled)
        XCTAssertNil(layer.presentation(support))
        XCTAssertNil(layer.presentation(["aps": ["alert": "x"]]))
        #if os(iOS)
        // And Support's own handler never takes an engagement notification.
        XCTAssertFalse(AppReferSupport.shared.handleNotification(info()))
        #endif
    }

    func testWrongInstallAccountExpiredAndMidChangeAreIgnoredButClaimed() async {
        XCTAssertEqual(layer.check(info(["iid": "ei_" + String(repeating: "b", count: 26)])), .ignored("other_install"))
        XCTAssertEqual(layer.check(info(["epoch": 1])), .ignored("other_account"))
        XCTAssertEqual(layer.check(info(["exp": (Date().timeIntervalSince1970 - 1) * 1000])), .ignored("expired"))
        XCTAssertEqual(layer.check(info(["v": 7])), .ignored("unsupported_version"))
        box.set(EngagementSnapshot(slot: "s", installId: iid, accountEpoch: nil, serial: 2, header: "h", trackedEvents: nil))
        XCTAssertEqual(layer.check(info()), .ignored("other_account"))
        box.set(nil)
        XCTAssertEqual(layer.check(info()), .ignored("not_started"))
        layer.handler = { self.events.append($0) }
        layer.setNavigationReady(true)
        let claimed = await respond(EngagementNotifications.defaultAction)
        XCTAssertTrue(claimed, "AppRefer's, so other handlers don't act on it")
        XCTAssertTrue(events.isEmpty, "but nothing navigates")
        XCTAssertEqual(layer.presentation(info()), false, "not shown in the foreground")
        await settle()
        let kinds = await receipts.kinds()
        XCTAssertTrue(kinds.isEmpty)
    }

    func testOpenIsDeliveredOnceAndOnlyWhenTheHostIsReady() async {
        _ = await respond(EngagementNotifications.defaultAction)
        _ = await respond(EngagementNotifications.defaultAction) // duplicate callback
        layer.handler = { self.events.append($0) }
        XCTAssertTrue(events.isEmpty, "held until navigation is ready")
        XCTAssertEqual(layer.pendingCount, 1)
        layer.setNavigationReady(true)
        XCTAssertEqual(events.map(\.kind), [.opened])
        XCTAssertEqual(events.first?.destination, "/setup")
        XCTAssertTrue(events.first!.isNavigation)
        _ = await respond(EngagementNotifications.defaultAction)
        XCTAssertEqual(events.count, 1)
        await settle()
        let kinds = await receipts.kinds()
        XCTAssertEqual(kinds, ["opened"])
    }

    func testDeferredNavigationIsDroppedWhenTheAccountChanges() async {
        layer.handler = { self.events.append($0) }
        _ = await respond(EngagementNotifications.defaultAction)
        // Signed out before the host was ready: the tap must not open A's screen for B.
        box.set(EngagementSnapshot(slot: "s", installId: iid, accountEpoch: 3, serial: 2, header: "h", trackedEvents: nil))
        layer.setNavigationReady(true)
        XCTAssertTrue(events.isEmpty)
        // An explicit reset clears what waits, too.
        box.set(EngagementSnapshot(slot: "s", installId: iid, accountEpoch: 2, serial: 3, header: "h", trackedEvents: nil))
        layer.setNavigationReady(false)
        _ = await respond(EngagementNotifications.defaultAction, info(["mid": "sparkly_live_j_q_nudge"]))
        layer.resetForAccountChange()
        layer.setNavigationReady(true)
        XCTAssertTrue(events.isEmpty)
    }

    func testButtonsMapByPositionWithinTheirOwnCategory() async {
        layer.handler = { self.events.append($0) }
        layer.setNavigationReady(true)
        _ = await respond("apprefer.action.0")
        XCTAssertEqual(events.last, AppReferEngagementNotificationEvent(kind: .action, messageId: "sparkly_live_finish-setup_abc_nudge", purpose: .reminders,
                                                                         destination: "/setup/next", actionId: "start", actionKind: .start))
        // Same message, the other button's category doesn't match: ignored.
        let ignored = await respond("apprefer.action.0", info(["mid": "sparkly_live_j_b_nudge"]), category: "apprefer.eng.open")
        XCTAssertTrue(ignored)
        _ = await respond("apprefer.action.5", info(["mid": "sparkly_live_j_c_nudge"]))
        _ = await respond("com.example.host.action", info(["mid": "sparkly_live_j_d_nudge"]))
        XCTAssertEqual(events.count, 1)
    }

    func testSnoozeReshowsOnceWithoutTheSnoozeButtonAndIsNotACompletion() async {
        layer.handler = { self.events.append($0) }
        _ = await respond("apprefer.action.1", info(["exp": (Date().timeIntervalSince1970 + 3 * 3600) * 1000]))
        XCTAssertEqual(events.map(\.kind), [.snoozed], "not navigation: delivered without readiness")
        XCTAssertFalse(events[0].isNavigation)
        let count = await system.snoozeCount()
        XCTAssertEqual(count, 1)
        let snooze = await system.lastSnooze()!
        XCTAssertEqual(snooze.category, "apprefer.eng.start")
        XCTAssertEqual(snooze.after, 3600, accuracy: 1, "60 minutes, inside the message's lifetime")
        XCTAssertEqual(snooze.userInfo["apprefer_snoozed"] as? Bool, true)
        // The re-shown copy: its only button is "Start", at position 0 of its own category.
        var shown = info(); shown["apprefer_snoozed"] = true
        layer.setNavigationReady(true)
        _ = await respond("apprefer.action.0", shown, category: "apprefer.eng.start")
        XCTAssertEqual(events.last?.actionId, "start")
        // Snoozing again (a stale copy) does nothing more.
        _ = await respond("apprefer.action.1")
        let again = await system.snoozeCount()
        XCTAssertEqual(again, 1)
        await settle()
        let kinds = await receipts.kinds()
        XCTAssertEqual(kinds, ["snooze", "action"])
    }

    func testAnIdentityChangeRemovesOnlyAppReferSnoozes() async {
        _ = await respond("apprefer.action.1", info(["exp": (Date().timeIntervalSince1970 + 3 * 3600) * 1000]))
        var held = await system.held()
        XCTAssertEqual(held.filter { $0.hasPrefix(snoozePrefix) }.count, 1)
        // Sign-out, sign-in, reset, deletion or an epoch learned from the server: A's re-show must not appear for B.
        await layer.identityInvalidated()
        held = await system.held()
        XCTAssertEqual(held, ["host.reminder", "apprefer.support.local"], "the app's and Support's own requests stay")
    }

    func testASnoozeWhoseAddLandsAfterAnIdentityChangeIsRemoved() async throws {
        await system.hold()
        let exp = (Date().timeIntervalSince1970 + 3 * 3600) * 1000
        let tap = Task { await self.respond("apprefer.action.1", self.info(["exp": exp])) }
        while !(await system.addStarted) { await Task.yield() }
        // The removal runs while the system add is still in flight: it finds nothing yet.
        await layer.identityInvalidated()
        var held = await system.held()
        XCTAssertFalse(held.contains { $0.hasPrefix(snoozePrefix) })
        await system.releaseAdd()
        _ = await tap.value
        held = await system.held()
        XCTAssertFalse(held.contains { $0.hasPrefix(snoozePrefix) }, "the late add is removed by its own fence")
    }

    func testASnoozeForAnIdentityThatAlreadyChangedIsNeverScheduled() async {
        let exp = (Date().timeIntervalSince1970 + 3 * 3600) * 1000
        await system.hold()
        let tap = Task { await self.respond("apprefer.action.1", self.info(["exp": exp])) }
        while !(await system.addStarted) { await Task.yield() }
        // The snapshot moved (e.g. a backend bind learned by the client) before the observer hop ran.
        box.set(EngagementSnapshot(slot: "s", installId: iid, accountEpoch: 3, serial: 2, header: "h", trackedEvents: nil))
        await system.releaseAdd()
        _ = await tap.value
        let held = await system.held()
        XCTAssertFalse(held.contains { $0.hasPrefix(snoozePrefix) })
    }

    func testDeferredEventsRecheckTheRealClock() async {
        var clock = Date()
        let timed = EngagementNotifications(snapshot: box, receipts: { _, _, _, _ in }, system: system,
                                            defaults: UserDefaults(suiteName: "n-\(UUID().uuidString)")!, now: { clock })
        var seen: [AppReferEngagementNotificationEvent] = []
        timed.handler = { seen.append($0) }
        let exp = (clock.timeIntervalSince1970 + 600) * 1000
        // Tapped while valid, but the app isn't ready to navigate yet.
        _ = await timed.handleResponse(userInfo: info(["exp": exp]), actionIdentifier: EngagementNotifications.defaultAction, categoryIdentifier: "")
        XCTAssertEqual(timed.pendingCount, 1)
        clock = clock.addingTimeInterval(601)
        timed.setNavigationReady(true)
        XCTAssertTrue(seen.isEmpty, "expired while waiting: never navigates")
        XCTAssertEqual(timed.pendingCount, 0)
        // A callback held for a missing handler is checked the same way.
        let late = EngagementNotifications(snapshot: box, receipts: { _, _, _, _ in }, system: system,
                                           defaults: UserDefaults(suiteName: "n-\(UUID().uuidString)")!, now: { clock })
        _ = late.presentation(info(["exp": (clock.timeIntervalSince1970 + 60) * 1000, "mid": "sparkly_live_j_late_nudge"]))
        clock = clock.addingTimeInterval(61)
        late.handler = { seen.append($0) }
        XCTAssertTrue(seen.isEmpty)
    }

    func testSnoozeNeverOutlivesTheMessage() async {
        _ = await respond("apprefer.action.1", info(["exp": (Date().timeIntervalSince1970 + 90) * 1000]))
        let count = await system.snoozeCount()
        XCTAssertEqual(count, 0)
    }

    func testForegroundReceivedAndDismissedNeedNoReadiness() async {
        layer.handler = { self.events.append($0) }
        XCTAssertEqual(layer.presentation(info()), true)
        XCTAssertEqual(layer.presentation(info()), true)
        _ = await respond(EngagementNotifications.dismissAction)
        XCTAssertEqual(events.map(\.kind), [.received, .dismissed])
        await settle()
        let kinds = await receipts.kinds()
        XCTAssertEqual(kinds, ["received", "dismissed"])
    }

    func testCategoriesCoverEveryKindPairWithLocalizedLabels() {
        let all = EngagementCategory.all { "L:\($0.rawValue)" }
        XCTAssertEqual(all.count, 16)
        XCTAssertEqual(Set(all.map(\.identifier)).count, 16)
        let pair = all.first { $0.identifier == "apprefer.eng.start.snooze" }!
        XCTAssertEqual(pair.actions.map(\.id), ["apprefer.action.0", "apprefer.action.1"])
        XCTAssertEqual(pair.actions.map(\.opensApp), [true, false])
        XCTAssertEqual(SupportStrings.bundled("engagement.action.snooze", language: "de"), "Später erinnern")
        XCTAssertEqual(SupportStrings.bundled("engagement.action.open", language: "ja"), "開く")
    }
}

/// Queued product events carry a stamp, never the credential, and get the header only while
/// the same install and identity are current.
final class EngagementEventHeaderTests: XCTestCase {
    private let key = "pk_live_sparkly000000000000000001"
    private var saved: EngagementSnapshot?

    override func setUp() { saved = EngagementClient.shared.snapshot.get() }
    override func tearDown() { EngagementClient.shared.snapshot.set(saved) }

    private func snapshot(serial: Int, epoch: Int? = 0, tracked: Set<String>? = nil) -> EngagementSnapshot {
        EngagementSnapshot(slot: EngagementClient.slot(for: key), installId: "ei_" + String(repeating: "a", count: 26), accountEpoch: epoch,
                           serial: serial, header: "ei_aaaa.eis_secret", trackedEvents: tracked)
    }

    func testStampAndHeaderRules() {
        EngagementClient.shared.snapshot.set(snapshot(serial: 1))
        let stamp = AppRefer.engagementStamp(eventName: "setup_started", apiKey: key)
        XCTAssertNotNil(stamp)
        XCTAssertFalse(stamp!.contains("secret"))
        XCTAssertEqual(AppRefer.engagementHeaders(stamp: stamp), ["X-AppRefer-Install": "ei_aaaa.eis_secret", "X-AppRefer-Install-Epoch": "0"])
        XCTAssertNil(AppRefer.engagementStamp(eventName: "_set_user_id", apiKey: key), "internal events never")
        XCTAssertNil(AppRefer.engagementStamp(eventName: "setup_started", apiKey: "pk_live_other0000000000000000001"), "another app's key never")
        // Identity moved on (reset, logout, sign-in): the queued event goes without it.
        EngagementClient.shared.snapshot.set(snapshot(serial: 2))
        XCTAssertNil(AppRefer.engagementHeaders(stamp: stamp))
        // Same serial, another epoch (a cold start learned a backend change): never current.
        EngagementClient.shared.snapshot.set(snapshot(serial: 1, epoch: 1))
        XCTAssertNil(AppRefer.engagementHeaders(stamp: stamp))
        // Mid account change: nothing is stamped.
        EngagementClient.shared.snapshot.set(snapshot(serial: 3, epoch: nil))
        XCTAssertNil(AppRefer.engagementStamp(eventName: "setup_started", apiKey: key))
        // Only the events the app chose.
        EngagementClient.shared.snapshot.set(snapshot(serial: 4, tracked: ["setup_started"]))
        XCTAssertNotNil(AppRefer.engagementStamp(eventName: "setup_started", apiKey: key))
        XCTAssertNil(AppRefer.engagementStamp(eventName: "paywall_viewed", apiKey: key))
        EngagementClient.shared.snapshot.set(nil)
        XCTAssertNil(AppRefer.engagementHeaders(stamp: stamp))
    }

    func testTrackedEventSendsTheHeaderAndAStaleQueuedOneDoesNot() async throws {
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let poster = HeaderPoster()
        let sdk = AppRefer(config: AppReferConfig(apiKey: key), storage: storage, trackingClient: poster, firstPartyClient: poster)
        EngagementClient.shared.snapshot.set(snapshot(serial: 10))
        _ = await sdk._trackEvent("setup_started", properties: nil, revenue: nil, currency: nil)
        var sent = await poster.sent
        XCTAssertEqual(sent.last?.headers["X-AppRefer-Install"], "ei_aaaa.eis_secret")
        XCTAssertEqual(sent.last?.headers["X-AppRefer-Install-Epoch"], "0")
        XCTAssertNil(sent.last?.body["X-AppRefer-Install"])
        // Queue one while offline, then the identity changes before it is sent.
        await poster.setStatus(nil)
        _ = await sdk._trackEvent("setup_completed", properties: nil, revenue: nil, currency: nil)
        let queued = try XCTUnwrap(storage.readPendingEvents())
        XCTAssertFalse(String(decoding: queued, as: UTF8.self).contains("eis_secret"), "never saved with the event")
        EngagementClient.shared.snapshot.set(snapshot(serial: 11))
        await poster.setStatus(200)
        storage.pendingEvents = try JSONEncoder().encode(try JSONDecoder().decode([PendingProductEvent].self, from: queued).map { var e = $0; e.nextAttempt = .distantPast; return e })
        await sdk.flushPendingEvents()
        sent = await poster.sent
        XCTAssertEqual(sent.last?.body["event_name"] as? String, "setup_completed")
        XCTAssertNil(sent.last?.headers["X-AppRefer-Install"])
    }
}

private actor HeaderPoster: AppReferPosting {
    var sent: [(body: [String: Any], headers: [String: String])] = []
    var status: Int? = 200
    func setStatus(_ s: Int?) { status = s }
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? { [:] }
    func event(_ body: [String: Any]) async -> Int? { sent.append((body, [:])); return status }
    func eventResponse(_ body: [String: Any], headers: [String: String]) async -> ProductEventResponse {
        sent.append((body, headers)); return ProductEventResponse(status: status, retryAfter: nil)
    }
}
