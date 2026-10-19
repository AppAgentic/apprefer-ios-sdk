import XCTest
@testable import AppRefer

/// Serves canned Support responses (or runs a callback first) and records every request.
private final class IdentityStub: URLProtocol, @unchecked Sendable {
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

final class SupportIdentityTests: XCTestCase {
    private let verified = #"{"identity":{"verified":true,"appUserId":"user_42","verifiedAt":"2026-10-19T12:00:00.000Z"}}"#
    private var storage: AppReferStorage!
    private var keychain: FakeDeviceIdKeychain!

    private func api() async -> SupportAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IdentityStub.self]
        keychain = FakeDeviceIdKeychain()
        storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        storage.setUserId("user_42")
        UserDefaults.standard.removeObject(forKey: "apprefer_support_profile")
        let api = SupportAPI(baseURL: "https://support.test", session: URLSession(configuration: config), deviceId: { nil },
                             userStorage: storage, tokenKeychain: keychain)
        await api.configure(apiKey: "pk_live_key")
        await api.setVerifyRetryDelays([1_000_000, 1_000_000])
        return api
    }
    private func isVerify(_ r: URLRequest) -> Bool { r.url!.path == "/api/support/v1/session/identity" }
    private func isSession(_ r: URLRequest) -> Bool { r.url!.path == "/api/support/v1/session" && r.httpMethod == "POST" }
    private var verifies: [(URLRequest, String)] { zip(IdentityStub.requests, IdentityStub.bodies).filter { isVerify($0.0) } }

    func testVerifiesTheCurrentSessionAndNeverStoresTheToken() async throws {
        IdentityStub.serve { r in self.isSession(r) ? .json(201, #"{"session":"ars_one","created":true}"#) : .json(200, self.verified) }
        let api = await api()
        let result = try await api.verifyIdentity("sit1.payload.sig")
        XCTAssertEqual(result, AppReferSupportIdentityVerification(verified: true, reason: nil, appUserId: "user_42"))
        let (request, body) = try XCTUnwrap(verifies.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AppRefer-Support-Session"), "ars_one")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String], ["identityToken": "sit1.payload.sig"])
        XCTAssertEqual(IdentityStub.requests.filter(isSession).count, 1, "the existing session is verified, not a new one")
        XCTAssertEqual(keychain.load(key: "apprefer_support_session"), .found("ars_one"), "only the session token is kept")
        XCTAssertFalse((UserDefaults.standard.string(forKey: "apprefer_support_profile") ?? "").contains("sit1"))
    }

    func testALostAnswerIsRetriedWithTheSameTokenOnTheSameSession() async throws {
        var calls = 0
        IdentityStub.serve { r in
            if self.isSession(r) { return .json(201, #"{"session":"ars_one","created":true}"#) }
            calls += 1
            return calls == 1 ? .json(503, #"{"error":"try again","reason":"unavailable"}"#) : calls == 2 ? .fail(.timedOut) : .json(200, self.verified)
        }
        let result = try await api().verifyIdentity("sit1.a.b")
        XCTAssertTrue(result.verified)
        XCTAssertEqual(verifies.count, 3)
        XCTAssertTrue(verifies.allSatisfy { $0.1.contains("sit1.a.b") && $0.0.value(forHTTPHeaderField: "X-AppRefer-Support-Session") == "ars_one" })
    }

    func testThrowsAfterRetriesAndReturnsRefusalsWithoutRetrying() async throws {
        IdentityStub.serve { r in self.isSession(r) ? .json(201, #"{"session":"ars_one"}"#) : .json(503, #"{"error":"down"}"#) }
        let api = await api()
        do { _ = try await api.verifyIdentity("sit1.a.b"); XCTFail("expected a throw") } catch let e as AppReferSupportError { XCTAssertEqual(e.status, 503) }
        XCTAssertEqual(verifies.count, 3)
        IdentityStub.serve { r in self.isSession(r) ? .json(201, #"{"session":"ars_one"}"#) : .json(200, #"{"identity":{"verified":false,"reason":"user_mismatch"}}"#) }
        let refused = try await api.verifyIdentity("sit1.a.b")
        XCTAssertEqual(refused, AppReferSupportIdentityVerification(verified: false, reason: "user_mismatch", appUserId: nil))
        XCTAssertEqual(verifies.count, 1)
    }

    func testResetWhileVerifyingAnswersAccountChanged() async throws {
        var api: SupportAPI!
        IdentityStub.serve { r in
            if self.isSession(r) { return .json(201, #"{"session":"ars_one"}"#) }
            if self.isVerify(r) {
                let done = DispatchSemaphore(value: 0)
                Task { await api.reset(); done.signal() }
                done.wait()
                return .json(200, self.verified)
            }
            return .json(200, #"{"ok":true}"#)
        }
        api = await self.api()
        let result = try await api.verifyIdentity("sit1.a.b")
        XCTAssertEqual(result.reason, "account_changed")
        XCTAssertFalse(result.verified)
    }

    func testAnotherUserWhileVerifyingAnswersAccountChanged() async throws {
        IdentityStub.serve { r in
            if self.isSession(r) { return .json(201, #"{"session":"ars_one"}"#) }
            self.storage.setUserId("user_77")
            return .json(200, self.verified)
        }
        let result = try await api().verifyIdentity("sit1.a.b")
        XCTAssertEqual(result.reason, "account_changed")
    }

    func testNothingIsSentForAClearedIdentityOrAnEmptyToken() async throws {
        IdentityStub.serve { _ in .json(200, self.verified) }
        let api = await api()
        let empty = try await api.verifyIdentity("  ")
        XCTAssertEqual(empty.reason, "malformed")
        storage.supportIdentityCleared = true
        let cleared = try await api.verifyIdentity("sit1.a.b")
        XCTAssertEqual(cleared.reason, "identity_cleared")
        XCTAssertTrue(IdentityStub.requests.isEmpty)
    }
}
