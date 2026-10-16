import XCTest
@testable import AppRefer

private final class EventPoster: AppReferPosting, @unchecked Sendable {
    var response: [String: Any]? = ["attribution": NSNull()]
    var status: Int? = 200
    var bodies: [[String: Any]] = []
    var cancellations = 0
    func post(_ path: String, body: [String: Any]) async -> [String: Any]? { response }
    func event(_ body: [String: Any]) async -> Int? { bodies.append(body); return status }
    func cancel() async { cancellations += 1 }
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
