#if os(iOS) || os(macOS)
import XCTest
import ImageIO
import UniformTypeIdentifiers
import UserNotifications
@testable import AppReferNotifications

/// Serves canned image responses with optional delays and redirects.
final class MediaStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var mime: String? = "image/png"
        var body = Data()
        var contentLength: Int?
        var delay: TimeInterval = 0
        var redirect: URL?
        var fail = false
        var never = false
    }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _reply = Reply()
    private nonisolated(unsafe) static var _requests: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func serve(_ reply: Reply) { lock.lock(); _reply = reply; _requests = []; lock.unlock() }
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let reply = Self._reply; Self._requests.append(request); Self.lock.unlock()
        if reply.never { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            guard !cancelled else { return }
            if reply.fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            if let target = reply.redirect {
                let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                return
            }
            var headers: [String: String] = [:]
            if let mime = reply.mime { headers["Content-Type"] = mime }
            headers["Content-Length"] = String(reply.contentLength ?? reply.body.count)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { cancelled = true }
}

/// Counts content-handler calls.
final class Handled: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UNNotificationContent] = []
    let expectation: XCTestExpectation
    init(_ e: XCTestExpectation) { expectation = e }
    func callAsFunction(_ content: UNNotificationContent) { lock.lock(); items.append(content); lock.unlock(); expectation.fulfill() }
    var calls: [UNNotificationContent] { lock.lock(); defer { lock.unlock() }; return items }
}

final class NotificationServiceTests: XCTestCase {
    static let host = "assets.example.com"
    static let imageURL = "https://assets.example.com/push/v1/hero.png"

    static func image(width: Int = 64, height: Int = 32, type: UTType = .png) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private var directory: URL!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("arn-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func service(hosts: Set<String> = [host], maxBytes: Int = 300_000, timeout: TimeInterval = 4, appGroup: String? = nil) -> AppReferNotificationService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStub.self]
        return AppReferNotificationService(configuration: .init(allowedImageHosts: hosts, maxImageBytes: maxBytes, timeout: timeout, appGroup: appGroup),
                                           sessionConfiguration: config, directory: directory)
    }

    private func request(_ overrides: [String: Any?] = ["img": imageURL]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Finish Garden"; content.body = "One step left."
        content.userInfo = ["apprefer": PayloadTests.object(overrides)]
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    private func run(_ service: AppReferNotificationService, _ request: UNNotificationRequest, timeout: TimeInterval = 6, after: ((AppReferNotificationService) -> Void)? = nil) -> [UNNotificationContent] {
        let e = expectation(description: "content handler")
        e.assertForOverFulfill = true
        let handled = Handled(e)
        XCTAssertTrue(service.didReceive(request, withContentHandler: { handled($0) }))
        after?(service)
        wait(for: [e], timeout: timeout)
        // Nothing else arrives later (download, deadline and expiry race).
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(handled.calls.count, 1)
        XCTAssertEqual(service.pendingCount, 0)
        return handled.calls
    }

    func testOtherNotificationsAreLeftToTheHost() {
        let s = service()
        let support = UNMutableNotificationContent()
        support.userInfo = ["apprefer": ["type": "support_reply", "conversationId": "cv_1"]]
        XCTAssertFalse(s.didReceive(UNNotificationRequest(identifier: "x", content: support, trigger: nil)) { _ in XCTFail("not ours") })
        XCTAssertFalse(s.didReceive(UNNotificationRequest(identifier: "y", content: UNMutableNotificationContent(), trigger: nil)) { _ in XCTFail("not ours") })
    }

    func testAttachesAValidImage() throws {
        MediaStub.serve(.init(body: Self.image()))
        let content = run(service(), request()).first!
        XCTAssertEqual(content.attachments.count, 1)
        XCTAssertEqual(content.title, "Finish Garden")
        XCTAssertEqual(MediaStub.requests.count, 1)
        XCTAssertNil(MediaStub.requests.first?.value(forHTTPHeaderField: "Cookie"))
    }

    func testJpegToo() {
        MediaStub.serve(.init(mime: "image/jpeg", body: Self.image(type: .jpeg)))
        XCTAssertEqual(run(service(), request(["img": "https://assets.example.com/push/v1/hero.jpg"])).first?.attachments.count, 1)
    }

    func testTextOnlyCases() {
        let png = Self.image()
        let cases: [(String, MediaStub.Reply, [String: Any?], Set<String>)] = [
            ("no image", .init(body: png), ["img": nil], [Self.host]),
            ("host not allowlisted", .init(body: png), ["img": Self.imageURL], ["other.example.com"]),
            ("empty allowlist", .init(body: png), ["img": Self.imageURL], []),
            ("expired", .init(body: png), ["img": Self.imageURL, "exp": (Date().timeIntervalSince1970 - 5) * 1000], [Self.host]),
            ("invalid payload", .init(body: png), ["img": Self.imageURL, "v": 9], [Self.host]),
            ("offline", .init(fail: true), ["img": Self.imageURL], [Self.host]),
            ("404", .init(status: 404, body: png), ["img": Self.imageURL], [Self.host]),
            ("wrong MIME", .init(mime: "text/html", body: png), ["img": Self.imageURL], [Self.host]),
            ("MIME and bytes differ", .init(mime: "image/png", body: Self.image(type: .jpeg)), ["img": Self.imageURL], [Self.host]),
            ("not an image", .init(body: Data("<html>".utf8)), ["img": Self.imageURL], [Self.host]),
            ("declared too large", .init(body: png, contentLength: 400_000), ["img": Self.imageURL], [Self.host]),
            ("streamed too large", .init(body: Data(count: 310_000) + png, contentLength: -1), ["img": Self.imageURL], [Self.host]),
            ("too many pixels", .init(body: Self.image(width: 3000, height: 10)), ["img": Self.imageURL], [Self.host]),
            ("redirect to another host", .init(redirect: URL(string: "https://internal.example.net/x.png")!), ["img": Self.imageURL], [Self.host]),
            ("redirect on the same host", .init(redirect: URL(string: "https://assets.example.com/other.png")!), ["img": Self.imageURL], [Self.host]),
        ]
        for (name, reply, overrides, hosts) in cases {
            MediaStub.serve(reply)
            let content = run(service(hosts: hosts), request(overrides)).first!
            XCTAssertTrue(content.attachments.isEmpty, name)
            XCTAssertEqual(content.body, "One step left.", name)
        }
        // Never fetched for these.
        MediaStub.serve(.init(body: png))
        _ = run(service(hosts: ["other.example.com"]), request())
        XCTAssertTrue(MediaStub.requests.isEmpty)
    }

    func testRedirectTargetIsNeverRequested() {
        MediaStub.serve(.init(redirect: URL(string: "https://169.254.169.254/latest/meta-data.png")!))
        _ = run(service(), request())
        XCTAssertEqual(MediaStub.requests.map { $0.url?.host }, [Self.host])
    }

    func testExtensionExpiryWinsOverASlowDownloadExactlyOnce() {
        MediaStub.serve(.init(body: Self.image(), delay: 1.0))
        let content = run(service(timeout: 5), request(), timeout: 3) { $0.serviceExtensionTimeWillExpire() }.first!
        XCTAssertTrue(content.attachments.isEmpty)
        // The download finishing afterwards changes nothing (checked by run's single-call assertion).
        Thread.sleep(forTimeInterval: 1.2)
    }

    func testOwnDeadlineSendsTextWhenTheServerNeverAnswers() {
        MediaStub.serve(.init(never: true))
        let start = Date()
        let content = run(service(timeout: 1), request(), timeout: 4).first!
        XCTAssertTrue(content.attachments.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.5)
    }

    func testExpiryCalledTwiceAndAfterDeliveryIsHarmless() {
        MediaStub.serve(.init(body: Self.image()))
        let s = service()
        _ = run(s, request())
        s.serviceExtensionTimeWillExpire()
        s.serviceExtensionTimeWillExpire()
    }

    func testAppGroupIdentityGatesTheImageAndRecordsReceived() {
        let group = "group.test.\(UUID().uuidString)"
        let shared = AppReferNotificationSharedState(appGroup: group)
        defer { UserDefaults(suiteName: group)?.removePersistentDomain(forName: group) }
        MediaStub.serve(.init(body: Self.image()))
        // Another account signed in: no fetch, no receipt.
        shared.setIdentity(.init(installId: PayloadTests.installId, accountEpoch: 3))
        XCTAssertTrue(run(service(appGroup: group), request()).first!.attachments.isEmpty)
        XCTAssertTrue(MediaStub.requests.isEmpty)
        XCTAssertTrue(shared.takeReceived().isEmpty)
        // Mid account change: nothing matches.
        shared.setIdentity(.init(installId: PayloadTests.installId, accountEpoch: nil))
        XCTAssertTrue(run(service(appGroup: group), request()).first!.attachments.isEmpty)
        // The same identity: image and a received marker (with the message's own proof only).
        shared.setIdentity(.init(installId: PayloadTests.installId, accountEpoch: 2))
        XCTAssertEqual(run(service(appGroup: group), request()).first!.attachments.count, 1)
        let markers = shared.takeReceived()
        XCTAssertEqual(markers.map(\.messageId), ["sparkly_live_finish-setup_abc_nudge"])
        XCTAssertEqual(markers.first?.receiptToken, PayloadTests.token)
        XCTAssertTrue(shared.takeReceived().isEmpty, "taken once")
    }

    func testLeftoverFilesAreRemoved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("old.png")
        try Data([1]).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        MediaStub.serve(.init(body: Self.image()))
        _ = run(service(), request())
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testConfigurationIsClamped() {
        let c = AppReferNotificationServiceConfiguration(allowedImageHosts: ["assets.example.com", "10.0.0.1", "localhost", "a.b:80"], maxImageBytes: 1 << 30, timeout: 600, maxPixelDimension: 100_000)
        XCTAssertEqual(c.allowedImageHosts, ["assets.example.com"])
        XCTAssertEqual(c.maxImageBytes, 5 * 1024 * 1024)
        XCTAssertEqual(c.timeout, 25)
        XCTAssertEqual(c.maxPixelDimension, 4096)
    }
}
#endif
