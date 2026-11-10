import XCTest
@testable import AppRefer

/// Serves canned Support responses and records every request with its body.
private final class AppContextStub: URLProtocol, @unchecked Sendable {
    enum Reply { case json(Int, String); case fail(URLError.Code) }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _requests: [URLRequest] = []
    private nonisolated(unsafe) static var _bodies: [String] = []
    private nonisolated(unsafe) static var _handler: ((URLRequest) -> Reply)?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static var bodies: [String] { lock.lock(); defer { lock.unlock() }; return _bodies }
    static func serve(_ handler: @escaping (URLRequest) -> Reply) { lock.lock(); _requests = []; _bodies = []; _handler = handler; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = ""
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body += String(decoding: buffer[0..<n], as: UTF8.self) }
        } else if let data = request.httpBody { body = String(decoding: data, as: UTF8.self) }
        Self.lock.lock()
        Self._requests.append(request); Self._bodies.append(body)
        let handler = Self._handler
        Self.lock.unlock()
        switch handler?(request) ?? .fail(.notConnectedToInternet) {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let status, let json):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class SupportAppContextTests: XCTestCase {
    private let created = #"{"conversation":{"id":"cv_1","subject":"Map issue","status":"open","preview":"Wrong green","lastMessageAt":"2026-11-10T12:00:00.000Z","lastFrom":"customer","unread":0},"messages":[],"persona":null}"#
    private let session = #"{"session":"ars_one","created":true}"#

    private func api() async -> SupportAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppContextStub.self]
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        storage.setUserId("user_42")
        UserDefaults.standard.removeObject(forKey: "apprefer_support_profile")
        let api = SupportAPI(baseURL: "https://support.test", session: URLSession(configuration: config), deviceId: { nil },
                             userStorage: storage, tokenKeychain: FakeDeviceIdKeychain())
        await api.configure(apiKey: "pk_live_key")
        await api.setStartRetryDelays([1_000_000, 1_000_000])
        return api
    }
    private func isSession(_ r: URLRequest) -> Bool { r.url!.path == "/api/support/v1/session" && r.httpMethod == "POST" }
    private func isStart(_ r: URLRequest) -> Bool { r.url!.path == "/api/support/v1/conversations" && r.httpMethod == "POST" }
    private var starts: [[String: Any]] {
        zip(AppContextStub.requests, AppContextStub.bodies).filter { isStart($0.0) }.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.1.utf8)) as? [String: Any]
        }
    }

    // MARK: Cleaning

    func testCleaningKeepsValidKeysTrimsCutsAndDropsEmptyValues() {
        let long = String(repeating: "a", count: 600)
        let cleaned = SupportAPI.cleanAppContext([
            "course_id": "  c_123 ",
            "Club": "x",              // upper case
            "hole-7": "x",            // dash
            "": "x",
            "é": "x",                 // not ASCII
            String(repeating: "k", count: 41): "x",
            String(repeating: "k", count: 40): "forty",
            "note": "line one\nline\ttwo\u{7}",
            "empty": "   ",
            "long": long,
        ])
        XCTAssertEqual(cleaned, [
            "course_id": "c_123",
            String(repeating: "k", count: 40): "forty",
            "note": "line one line two",
            "long": String(repeating: "a", count: 500),
        ])
    }

    func testCleaningKeepsTheFirstTwentyKeysInSortedOrder() {
        var input: [String: String] = [:]
        for i in 0..<30 { input[String(format: "k%02d", i)] = "v\(i)" }
        input["a_empty"] = ""   // dropped, so it takes no place
        let cleaned = SupportAPI.cleanAppContext(input)
        XCTAssertEqual(cleaned.count, 20)
        XCTAssertEqual(cleaned.keys.sorted(), (0..<20).map { String(format: "k%02d", $0) })
        XCTAssertTrue(SupportAPI.cleanAppContext(["Bad": "x", "ok": ""]).isEmpty)
    }

    func testEmojiAreNotSplitWhenCut() {
        let value = String(repeating: "👨‍👩‍👧", count: 501)
        let cleaned = SupportAPI.cleanAppContext(["family": value])
        XCTAssertEqual(cleaned["family"], String(repeating: "👨‍👩‍👧", count: 500))
    }

    // MARK: send

    func testSendPostsTheAppDataInContextAndReturnsTheConversationId() async throws {
        AppContextStub.serve { r in self.isSession(r) ? .json(201, self.session) : .json(201, self.created) }
        let api = await api()
        let id = try await api.startConversation(text: "  Wrong green on hole 7 ", subject: "Map issue",
                                                 appContext: ["course_id": "c_123", "hole": "7", "Bad Key": "x"])
        XCTAssertEqual(id, "cv_1")
        let body = try XCTUnwrap(starts.first)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(body["text"] as? String, "Wrong green on hole 7", "the app data is never put in the text")
        XCTAssertEqual(body["subject"] as? String, "Map issue")
        let context = try XCTUnwrap(body["context"] as? [String: Any])
        XCTAssertEqual(context["platform"] as? String, "ios", "the usual context stays")
        XCTAssertEqual(context["app"] as? [String: String], ["course_id": "c_123", "hole": "7"])
        XCTAssertNotNil(UUID(uuidString: body["clientMessageId"] as? String ?? ""))
        XCTAssertNil(body["attachmentIds"])
        let request = try XCTUnwrap(AppContextStub.requests.first(where: isStart))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AppRefer-Support-Session"), "ars_one")
    }

    func testSendWithoutUsableDataOmitsApp() async throws {
        AppContextStub.serve { r in self.isSession(r) ? .json(201, self.session) : .json(201, self.created) }
        let api = await api()
        _ = try await api.startConversation(text: "Hi", subject: "  ", appContext: ["Nope": "x"])
        let body = try XCTUnwrap(starts.first)
        XCTAssertNil((body["context"] as? [String: Any])?["app"])
        XCTAssertNil(body["subject"], "a blank subject is left out")
    }

    func testTransientFailuresAreRetriedWithTheSameClientMessageId() async throws {
        var calls = 0
        AppContextStub.serve { r in
            if self.isSession(r) { return .json(201, self.session) }
            calls += 1
            return calls == 1 ? .json(503, #"{"error":"down"}"#) : calls == 2 ? .fail(.timedOut) : .json(200, self.created)
        }
        let api = await api()
        let id = try await api.startConversation(text: "Wrong green", subject: nil, appContext: ["course_id": "c_1"])
        XCTAssertEqual(id, "cv_1")
        XCTAssertEqual(starts.count, 3)
        let ids = Set(starts.compactMap { $0["clientMessageId"] as? String })
        XCTAssertEqual(ids.count, 1, "every attempt uses the same clientMessageId")
        XCTAssertTrue(starts.allSatisfy { (($0["context"] as? [String: Any])?["app"] as? [String: String]) == ["course_id": "c_1"] })
    }

    func testEachSendHasItsOwnClientMessageId() async throws {
        AppContextStub.serve { r in self.isSession(r) ? .json(201, self.session) : .json(201, self.created) }
        let api = await api()
        _ = try await api.startConversation(text: "One", subject: nil, appContext: [:])
        _ = try await api.startConversation(text: "Two", subject: nil, appContext: [:])
        XCTAssertEqual(Set(starts.compactMap { $0["clientMessageId"] as? String }).count, 2)
    }

    func testThrowsAfterTwoRetriesAndNeverRetriesARefusal() async throws {
        AppContextStub.serve { r in self.isSession(r) ? .json(201, self.session) : .json(429, #"{"error":"slow down"}"#) }
        let api = await api()
        do { _ = try await api.startConversation(text: "Hi", subject: nil, appContext: [:]); XCTFail("expected a throw") }
        catch let e as AppReferSupportError { XCTAssertEqual(e.status, 429) }
        XCTAssertEqual(starts.count, 3)

        AppContextStub.serve { r in self.isSession(r) ? .json(201, self.session) : .json(400, #"{"error":"bad"}"#) }
        do { _ = try await api.startConversation(text: "Hi", subject: nil, appContext: [:]); XCTFail("expected a throw") }
        catch let e as AppReferSupportError { XCTAssertEqual(e.status, 400) }
        XCTAssertEqual(starts.count, 1)
    }

    func testEmptyTextThrowsAndSendsNothing() async throws {
        AppContextStub.serve { _ in .json(201, self.created) }
        let api = await api()
        do { _ = try await api.startConversation(text: " \n ", subject: "x", appContext: ["a": "b"]); XCTFail("expected a throw") }
        catch let e as AppReferSupportError { XCTAssertEqual(e.code, "EMPTY_TEXT") }
        XCTAssertTrue(AppContextStub.requests.isEmpty)
    }

    func testResetWhileSendingThrowsCancellation() async throws {
        var api: SupportAPI!
        AppContextStub.serve { r in
            if self.isSession(r) { return .json(201, self.session) }
            let done = DispatchSemaphore(value: 0)
            Task { await api.reset(); done.signal() }
            done.wait()
            return .json(201, self.created)
        }
        api = await self.api()
        do { _ = try await api.startConversation(text: "Hi", subject: nil, appContext: [:]); XCTFail("expected a throw") }
        catch is CancellationError {}
        XCTAssertEqual(starts.count, 1, "never retried for the next account")
    }

    // MARK: Composer path

    func testComposerStartSendsAppOnlyWhenGiven() async throws {
        AppContextStub.serve { r in self.isSession(r) ? .json(201, self.session) : .json(201, self.created) }
        let api = await api()
        _ = try await api.start(text: "A", attachmentIds: [], clientMessageId: "m1", appContext: ["source": "map_report"])
        _ = try await api.start(text: "B", attachmentIds: [], clientMessageId: "m2")
        XCTAssertEqual((starts[0]["context"] as? [String: Any])?["app"] as? [String: String], ["source": "map_report"])
        XCTAssertNil((starts[1]["context"] as? [String: Any])?["app"])
    }
}
