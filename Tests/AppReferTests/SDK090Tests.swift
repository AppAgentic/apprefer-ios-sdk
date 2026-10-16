import XCTest
@testable import AppRefer

private final class EventPoster: AppReferPosting, @unchecked Sendable {
    var response: [String: Any]? = ["attribution": NSNull()]
    var status: Int? = 200
    var bodies: [[String: Any]] = []
    var cancellations = 0
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? { response }
    func event(_ body: [String: Any]) async -> Int? { bodies.append(body); return status }
    func cancelEvents() async { cancellations += 1 }
}

private final class Support090Protocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class SDK090Tests: XCTestCase {
    private func fixture() -> (AppRefer, AppReferStorage, EventPoster) {
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let poster = EventPoster()
        return (AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster), storage, poster)
    }

    func testQueueSurvivesNewSDKAndRetriesStableID() async throws {
        let (sdk, storage, poster) = fixture()
        poster.status = nil
        let result = await sdk._trackEvent("offline", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(result, .queued)
        var saved = try JSONDecoder().decode([PendingProductEvent].self, from: storage.pendingEvents!)
        XCTAssertEqual(saved.count, 1)
        let id = saved[0].id
        saved[0].nextAttempt = .distantPast
        storage.pendingEvents = try JSONEncoder().encode(saved)
        let next = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        poster.status = 200
        await next.flushPendingEvents()
        XCTAssertEqual(poster.bodies.map { $0["eventId"] as? String }, [id, id])
        XCTAssertEqual(try JSONDecoder().decode([PendingProductEvent].self, from: storage.pendingEvents!).count, 0)
        await sdk._clearPendingEvents()
    }

    func test4xxDropped5xxQueuedAndClearCancels() async throws {
        let (sdk, storage, poster) = fixture()
        poster.status = 422
        let rejected = await sdk._trackEvent("bad", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(rejected, .dropped)
        poster.status = 503
        let queued = await sdk._trackEvent("retry", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(queued, .queued)
        await sdk._clearPendingEvents()
        XCTAssertNil(storage.pendingEvents)
        XCTAssertGreaterThan(poster.cancellations, 0)
    }

    func testQueueBoundsAndExpiry() async throws {
        let (sdk, storage, _) = fixture()
        let events = (0..<1003).map {
            PendingProductEvent(id: "\($0)", body: Data("{}".utf8), created: $0 == 1002 ? .distantPast : Date(), attempts: 0, nextAttempt: .distantFuture)
        }
        storage.pendingEvents = try JSONEncoder().encode(events)
        await sdk.flushPendingEvents()
        let saved = try JSONDecoder().decode([PendingProductEvent].self, from: storage.pendingEvents!)
        XCTAssertEqual(saved.count, 1000)
        XCTAssertEqual(saved.first?.id, "2")
        await sdk._clearPendingEvents()
    }

    func testResetKeepsInstallButClearsUserQueueAndIsIdempotent() async {
        let (sdk, storage, poster) = fixture()
        storage.setUserId("A")
        storage.setAttributionCache("{\"network\":\"meta\",\"matchType\":\"click\"}")
        let id = storage.deviceId()
        poster.status = nil
        _ = await sdk._trackEvent("A-event", properties: nil, revenue: nil, currency: nil)
        await sdk._reset()
        await sdk._reset()
        XCTAssertNil(storage.getUserId())
        XCTAssertNil(storage.pendingEvents)
        XCTAssertEqual(storage.deviceId(), id)
        XCTAssertEqual(storage.getCachedAttribution()?.network, "meta")
        await sdk._setUserIdForTesting("B")
        XCTAssertEqual(storage.getUserId(), "B")
    }

    func testOrganicIsDifferentFromNetworkFailure() async {
        let (organic, _, _) = fixture()
        _ = await organic._configure()
        if case .organic = await organic.attributionResult() {} else { XCTFail("Expected organic") }
        let (failed, _, poster) = fixture()
        poster.response = nil
        _ = await failed._configure()
        if case .failed = await failed.attributionResult() {} else { XCTFail("Expected failure") }
        let (unknown, _, unknownPoster) = fixture()
        unknownPoster.response = [:]
        _ = await unknown._configure()
        if case .failed = await unknown.attributionResult() {} else { XCTFail("Missing status is not organic") }
    }

    func testKillSwitchDropsQueue() async {
        let (sdk, storage, poster) = fixture()
        poster.status = nil
        _ = await sdk._trackEvent("offline", properties: nil, revenue: nil, currency: nil)
        storage.setSdkEnabled(false)
        await sdk.flushPendingEvents()
        XCTAssertNil(storage.pendingEvents)
        await sdk._clearPendingEvents()
    }

    func testSupportOnlyTwoAccountsAndRevocation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Support090Protocol.self]
        let api = SupportAPI(baseURL: "https://support.test", session: URLSession(configuration: config))
        await api.reset()
        await api.configure(apiKey: "pk_support_only")
        var minted = 0
        var tokens: [String] = []
        var revoked: [String] = []
        Support090Protocol.handler = { req in
            XCTAssertFalse(req.url!.path.contains("/track/"))
            if req.httpMethod == "DELETE" {
                revoked.append(req.value(forHTTPHeaderField: "X-AppRefer-Support-Session")!)
                return (200, "{}")
            }
            if req.url!.path.hasSuffix("/session") {
                minted += 1
                return (201, "{\"session\":\"token-\(minted)\"}")
            }
            tokens.append(req.value(forHTTPHeaderField: "X-AppRefer-Support-Session")!)
            return (200, minted == 1 ? "{\"conversations\":[{\"id\":\"A-private\",\"subject\":\"A\",\"status\":\"open\",\"preview\":\"secret\",\"lastMessageAt\":\"2026-10-16T00:00:00Z\",\"lastFrom\":\"team\",\"unread\":1}]}" : "{\"conversations\":[]}")
        }
        AppReferStorage().setUserId("A")
        await api.setIdentity(name: "A", email: "a@example.test")
        let first = try await api.conversations()
        XCTAssertEqual(first.count, 1)
        await api.reset()
        AppReferStorage().clearUser()
        AppReferStorage().setUserId("B")
        await api.setIdentity(name: "B", email: "b@example.test")
        let conversations = try await api.conversations()
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertEqual(tokens, ["token-1", "token-2"])
        XCTAssertEqual(revoked, ["token-1"])
        await api.reset()
        Support090Protocol.handler = nil
        AppReferStorage().clearUser()
    }

    func testSupportBeforeConfigureErrors() async {
        let api = SupportAPI()
        do { _ = try await api.conversations(); XCTFail("Should require key") }
        catch let error as AppReferSupportError { XCTAssertEqual(error.status, 0) }
        catch { XCTFail("\(error)") }
    }
}

private actor Suspended090Poster: AppReferPosting {
    private var configureReply: CheckedContinuation<[String: Any]?, Never>?
    private var eventReply: CheckedContinuation<Int?, Never>?
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { configureReply = $0 }
    }
    func event(_ body: [String: Any]) async -> Int? {
        await withCheckedContinuation { eventReply = $0 }
    }
    func cancel() async {
        configureReply?.resume(returning: nil); configureReply = nil
        eventReply?.resume(returning: nil); eventReply = nil
    }
    func waitForConfigure() async { while configureReply == nil { await Task.yield() } }
    func waitForEvent() async { while eventReply == nil { await Task.yield() } }
    func finishConfigure() { configureReply?.resume(returning: ["attribution": ["network": "meta"]]); configureReply = nil }
    func finishEvent() { eventReply?.resume(returning: 503); eventReply = nil }
}

extension SDK090Tests {
    func testLateAttributionCannotRestoreStateAfterReset() async {
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let poster = Suspended090Poster()
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test", userId: "A"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        let request = Task { await sdk._configure() }
        await poster.waitForConfigure()
        await sdk._reset()
        await poster.finishConfigure()
        _ = await request.value
        XCTAssertNil(storage.getCachedAttribution())
        XCTAssertNil(storage.getUserId())
        XCTAssertFalse(storage.isMatchRequestAttempted())
    }

    func testLateEventCannotRepopulateClearedQueue() async {
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let poster = Suspended090Poster()
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        let request = Task { await sdk._trackEvent("A-event", properties: nil, revenue: nil, currency: nil) }
        await poster.waitForEvent()
        await sdk._clearPendingEvents()
        await poster.finishEvent()
        let result = await request.value
        XCTAssertEqual(result, .dropped)
        XCTAssertNil(storage.pendingEvents)
    }

    func testResetBeforeConfigureIsSafe() async {
        await AppRefer.reset()
        await AppRefer.reset()
        await AppRefer.clearPendingEvents()
        XCTAssertNil(AppReferStorage().getUserId())
    }
}

extension SDK090Tests {
    func testAtomicQueueSurvivesNewStorageInstance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("events.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let poster = EventPoster()
        poster.status = nil
        let storage = AppReferStorage(defaults: defaults, keychain: FakeDeviceIdKeychain(), eventFileURL: file)
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        _ = await sdk._trackEvent("offline", properties: nil, revenue: nil, currency: nil)
        var saved = try JSONDecoder().decode([PendingProductEvent].self, from: Data(contentsOf: file))
        let id = saved[0].id
        saved[0].nextAttempt = .distantPast
        try storage.writePendingEvents(JSONEncoder().encode(saved))
        let nextStorage = AppReferStorage(defaults: defaults, keychain: FakeDeviceIdKeychain(), eventFileURL: file)
        let next = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: nextStorage, trackingClient: poster, firstPartyClient: poster)
        poster.status = 200
        await next.flushPendingEvents()
        XCTAssertEqual(poster.bodies.last?["eventId"] as? String, id)
        XCTAssertEqual(try JSONDecoder().decode([PendingProductEvent].self, from: Data(contentsOf: file)).count, 0)
        await sdk._clearPendingEvents()
    }

    func testQueueWriteFailureDoesNotClaimQueuedOrSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file, not directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let poster = EventPoster()
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain(), eventFileURL: directory.appendingPathComponent("events.json"))
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        let result = await sdk._trackEvent("offline", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(result, .dropped)
        XCTAssertTrue(poster.bodies.isEmpty)
    }
}

extension SDK090Tests {
    func testPendingATTIsNeverOrganicIncludingCache() async throws {
        let (sdk, storage, poster) = fixture()
        poster.response = ["attribution": ["network": "organic", "trackingDecisionPending": true]]
        _ = await sdk._configure()
        if case .pending = await sdk.attributionResult() {} else { XCTFail("ATT is pending") }
        let cached = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        if case .pending = await cached.attributionResult() {} else { XCTFail("Cached held decision is pending") }
        poster.response = nil
        _ = await sdk._configure()
        if case .pending = await sdk.attributionResult() {} else { XCTFail("Offline does not confirm held attribution") }
    }

    func testFailedReportKeepsConfirmedMeta() async {
        let (sdk, storage, poster) = fixture()
        storage.setAttributionCache("{\"network\":\"meta\",\"match_type\":\"click\"}")
        poster.response = nil
        _ = await sdk._configure()
        if case .attributed(let a) = await sdk.attributionResult() { XCTAssertEqual(a.network, "meta") }
        else { XCTFail("Confirmed cache wins") }
    }

    func testRetryableStatusesStopBacklogAndRespectRetryAfter() async throws {
        for status in [408, 429, 503] {
            let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
            let poster = RateLimitedPoster(status: status)
            let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
            storage.pendingEvents = try JSONEncoder().encode((0..<3).map { PendingProductEvent(id: "\($0)", body: Data("{}".utf8), created: Date(), attempts: 0, nextAttempt: .distantPast) })
            await sdk.flushPendingEvents()
            XCTAssertEqual(poster.calls, 1)
            let saved = try JSONDecoder().decode([PendingProductEvent].self, from: storage.pendingEvents!)
            XCTAssertEqual(saved.count, 3)
            XCTAssertTrue(saved.allSatisfy { $0.nextAttempt.timeIntervalSinceNow > 59 })
            await sdk._clearPendingEvents()
        }
        XCTAssertEqual(AppReferHTTPClient.retryAfter("120"), 120)
        XCTAssertNil(AppReferHTTPClient.retryAfter("bad"))
    }

    func testTrackWaitsOnlyForItsEvent() async throws {
        let (sdk, storage, poster) = fixture()
        storage.pendingEvents = try JSONEncoder().encode((0..<20).map { PendingProductEvent(id: "old-\($0)", body: Data("{}".utf8), created: Date(), attempts: 0, nextAttempt: .distantPast) })
        let result = await sdk._trackEvent("own", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(poster.bodies.count, 1)
        await sdk._clearPendingEvents()
    }

    func testCorruptQueueIsQuarantinedAndNewEventsWork() async throws {
        let (sdk, storage, _) = fixture()
        storage.pendingEvents = Data("broken json".utf8)
        let result = await sdk._trackEvent("new", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(result, .sent)
        await sdk._clearPendingEvents()
    }

    func testStaleComposeAfterResetCannotMintUploadOrSend() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Support090Protocol.self]
        let api = SupportAPI(baseURL: "https://support.test", session: URLSession(configuration: config))
        await api.configure(apiKey: "pk_test")
        let epoch = api.actionGeneration
        await api.reset()
        var calls = 0
        Support090Protocol.handler = { _ in calls += 1; return (200, "{}") }
        do { _ = try await api.upload(Data(), generation: epoch); XCTFail("Stale upload") } catch {}
        do { _ = try await api.start(text: "A", attachmentIds: [], clientMessageId: "12345678", generation: epoch); XCTFail("Stale compose") } catch {}
        do { _ = try await api.send("A-thread", text: "A", attachmentIds: [], clientMessageId: "12345678", generation: epoch); XCTFail("Stale send") } catch {}
        XCTAssertEqual(calls, 0)
    }


}
private final class RateLimitedPoster: AppReferPosting, @unchecked Sendable {
    let status: Int
    var calls = 0
    init(status: Int) { self.status = status }
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? { nil }
    func eventResponse(_ body: [String: Any]) async -> ProductEventResponse {
        calls += 1
        return ProductEventResponse(status: status, retryAfter: 60)
    }
}

extension SDK090Tests {
    func testClearingEventsDoesNotCancelInFlightConfigure() async {
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let poster = Suspended090Poster()
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        let configure = Task { await sdk._configure() }
        await poster.waitForConfigure()
        await sdk._clearPendingEvents()
        await poster.finishConfigure()
        let attribution = await configure.value
        XCTAssertEqual(attribution?.network, "meta")
    }

    func testReconfigureUsesSameQueueAndStaleDrainCannotOverwriteNewEvents() async {
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let old = Suspended090Poster()
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_A"), storage: storage, trackingClient: old, firstPartyClient: old)
        let a = Task { await sdk._trackEvent("A", properties: nil, revenue: nil, currency: nil) }
        await old.waitForEvent()
        let next = EventPoster()
        await sdk.replaceConfiguration(AppReferConfig(apiKey: "pk_B"), trackingClient: next, firstPartyClient: next)
        let b = await sdk._trackEvent("B", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(b, .sent)
        await old.finishEvent()
        let result = await a.value
        XCTAssertEqual(result, .dropped)
        // Reconfigure preserves the old durable event; stale completion must not delete it.
        let saved = try? JSONDecoder().decode([PendingProductEvent].self, from: storage.pendingEvents ?? Data())
        XCTAssertEqual(saved?.count, 1)
        await sdk._clearPendingEvents()
    }

    func testClearReleasesDrainForNewAccountBeforeOldCompletion() async {
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let poster = FirstEventSuspendedPoster()
        let sdk = AppRefer(config: AppReferConfig(apiKey: "pk_test"), storage: storage, trackingClient: poster, firstPartyClient: poster)
        let a = Task { await sdk._trackEvent("A", properties: nil, revenue: nil, currency: nil) }
        await poster.waitForEvent()
        await sdk._clearPendingEvents()
        let b = await sdk._trackEvent("B", properties: nil, revenue: nil, currency: nil)
        XCTAssertEqual(b, .sent)
        await poster.finishEvent()
        let result = await a.value
        XCTAssertEqual(result, .dropped)
        await sdk._clearPendingEvents()
    }
}
private actor FirstEventSuspendedPoster: AppReferPosting {
    var first = true
    var continuation: CheckedContinuation<Int?, Never>?
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? { nil }
    func event(_ body: [String: Any]) async -> Int? {
        if first { first = false; return await withCheckedContinuation { continuation = $0 } }
        return 200
    }
    func waitForEvent() async { while continuation == nil { await Task.yield() } }
    func finishEvent() { continuation?.resume(returning: 503); continuation = nil }
}

extension SDK090Tests {
    func testConfigureStartedBeforePublicResetCannotRestoreUserA() async {
        let (sdk, storage, poster) = fixture()
        let epoch = AppRefer.accountEpoch()
        await AppRefer.reset()
        await sdk.replaceConfiguration(AppReferConfig(apiKey: "pk_test", userId: "A"), expectedAccountEpoch: epoch, trackingClient: poster, firstPartyClient: poster)
        _ = await sdk._configure(expectedAccountEpoch: epoch)
        XCTAssertNil(storage.getUserId())
        XCTAssertFalse(storage.isMatchRequestAttempted())
    }
}
