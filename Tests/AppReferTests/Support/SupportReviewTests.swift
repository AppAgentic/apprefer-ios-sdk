import XCTest
@testable import AppRefer
#if os(iOS)
import SwiftUI
import UIKit
#endif

/// Serves canned Support responses and records every request (review cards).
private final class ReviewStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _requests: [URLRequest] = []
    private nonisolated(unsafe) static var _handler: ((URLRequest) -> (Int, String))?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func serve(_ handler: @escaping (URLRequest) -> (Int, String)) { lock.lock(); _requests = []; _handler = handler; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let handler = Self._handler
        Self.lock.unlock()
        let (status, json) = handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private let reviewJSON = #"{"cardId":"rvc_0123456789abcdef01234567","status":"available","reason":null,"store":"app_store","url":"https://apps.apple.com/app/id1234567890?action=write-review"}"#

final class SupportReviewTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        SupportStrings.forcedLanguage = "en"
    }

    override func tearDown() {
        SupportStrings.forcedLanguage = nil
        super.tearDown()
    }

    private func card(_ json: String = reviewJSON) throws -> AppReferSupportReviewCard {
        try JSONDecoder().decode(AppReferSupportReviewCard.self, from: Data(json.utf8))
    }

    func testDecodesReviewCardsAndOldPayloadsWithoutThem() throws {
        let m = try JSONDecoder().decode(AppReferSupportMessage.self, from: Data(#"{"id":"m2","from":"team","authorName":"Jay","text":"Thanks!","createdAt":"2026-10-19T12:00:00.000Z","attachments":[],"review":\#(reviewJSON)}"#.utf8))
        XCTAssertEqual(m.review?.cardId, "rvc_0123456789abcdef01234567")
        let old = try JSONDecoder().decode(AppReferSupportMessage.self, from: Data(#"{"id":"m3","from":"team","text":"Hi","createdAt":"2026-10-19T12:00:00.000Z","attachments":[]}"#.utf8))
        XCTAssertNil(old.review)
    }

    func testOnlyTheAppStoreWriteReviewPageIsEverOpened() throws {
        XCTAssertEqual(SupportReviewLink.validated("https://apps.apple.com/app/id1234567890?action=write-review")?.absoluteString,
                       "https://apps.apple.com/app/id1234567890?action=write-review")
        for bad in [
            "http://apps.apple.com/app/id1234567890?action=write-review",
            "https://apps.apple.com.evil.example/app/id1234567890?action=write-review",
            "https://evil.example/app/id1234567890?action=write-review",
            "https://apps.apple.com/app/id1234567890",
            "https://apps.apple.com/app/id1234567890?action=write-review&redirect=https://evil.example",
            "https://apps.apple.com/app/id1234567890/../x?action=write-review",
            "https://user@apps.apple.com/app/id1234567890?action=write-review",
            "https://apps.apple.com:444/app/id1234567890?action=write-review",
            "https://play.google.com/store/apps/details?id=com.app",
            "itms-apps://apps.apple.com/app/id1234567890?action=write-review",
            "javascript:alert(1)", "",
        ] {
            XCTAssertNil(SupportReviewLink.validated(bad), bad)
        }
        // A server sending anything else gets an honest "no store page", never a dead or foreign link.
        let foreign = try card(reviewJSON.replacingOccurrences(of: "https://apps.apple.com", with: "https://evil.example"))
        XCTAssertEqual(SupportReviewLook.of(foreign), .unsupported)
    }

    func testLookFollowsServerState() throws {
        if case .open(let url) = SupportReviewLook.of(try card()) { XCTAssertEqual(url.host, "apps.apple.com") } else { XCTFail("open") }
        let revoked = try card(#"{"cardId":"rvc_1","status":"unavailable","reason":"revoked","store":null,"url":null}"#)
        XCTAssertEqual(SupportReviewLook.of(revoked), .unavailable)
        let elsewhere = try card(#"{"cardId":"rvc_1","status":"unavailable","reason":"not_on_platform","store":null,"url":null}"#)
        XCTAssertEqual(SupportReviewLook.of(elsewhere), .unsupported)
    }

    func testNeutralCopyInEveryLanguageNamesTheStore() {
        XCTAssertEqual(SupportStrings.text("support.review.title"), "Share your experience")
        XCTAssertEqual(SupportStrings.text("support.review.body.appStore"), "If you'd like, you can write a review on the App Store.")
        XCTAssertEqual(SupportStrings.text("support.review.a11y.hint.appStore"), "Opens the App Store")
        XCTAssertEqual(SupportReviewLink.storeKey("app_store"), "appStore")
        XCTAssertEqual(SupportStrings.text("support.review.open"), "Write a review")
        for lang in ["ar", "de", "ja", "pt-BR", "zh-Hant"] {
            SupportStrings.forcedLanguage = lang
            let body = SupportStrings.text("support.review.body.appStore")
            XCTAssertTrue(body.contains("App Store"), lang)
            XCTAssertNotEqual(SupportStrings.text("support.review.open"), "Write a review", lang)
        }
        for key in ["support.review.title", "support.review.body.appStore", "support.review.open"] {
            XCTAssertFalse(SupportStrings.text(key).lowercased().contains("star"), "never asks for stars")
        }
    }

    func testShownIdIsStableAndValid() {
        let id = supportReviewShownId("rvc_0123456789abcdef01234567")
        XCTAssertEqual(id, supportReviewShownId("rvc_0123456789abcdef01234567"))
        XCTAssertNotNil(id.range(of: #"^[A-Za-z0-9_-]{8,64}$"#, options: .regularExpression))
    }

    func testReceiptsAndRefreshUseTheReviewRoutes() async throws {
        ReviewStub.serve { r in
            if r.url!.path == "/api/support/v1/session" { return (201, #"{"session":"ars_one","created":true}"#) }
            if r.url!.path.hasSuffix("/reviews") { return (200, #"{"reviews":[\#(reviewJSON),null]}"#) }
            return (201, #"{"eventId":"rve_x","duplicate":false,"review":\#(reviewJSON)}"#)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewStub.self]
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let api = SupportAPI(baseURL: "https://support.test", session: URLSession(configuration: config), deviceId: { nil },
                             userStorage: storage, tokenKeychain: FakeDeviceIdKeychain())
        await api.configure(apiKey: "pk_live_key")
        let cards = try await api.reviewCards("cv1")
        XCTAssertEqual(cards.count, 1)
        let q = SupportOfferReceipts(defaults: defaults)
        q.enqueue(SupportOfferReceipt(conversationId: "cv1", cardId: "rvc_0123456789abcdef01234567", kind: "opened", clientEventId: "open_rvc00001", occurredAt: SupportOfferClock.iso(Date())))
        await api.flushOfferReceipts(q)
        XCTAssertTrue(q.pending.isEmpty)
        let calls = ReviewStub.requests.filter { $0.url!.path != "/api/support/v1/session" }
        XCTAssertEqual(calls[0].url!.path, "/api/support/v1/conversations/cv1/reviews")
        XCTAssertEqual(calls[0].url!.query, "platform=ios")
        XCTAssertTrue(calls[0].value(forHTTPHeaderField: "X-AppRefer-Support-Features")?.contains("reviews") == true)
        XCTAssertEqual(calls[1].url!.path, "/api/support/v1/conversations/cv1/reviews/rvc_0123456789abcdef01234567/events")
    }

    #if os(iOS)
    @MainActor
    func testTappingOpensTheValidatedStorePageAndARefusalDoesNot() async throws {
        var opened: [URL] = []
        let original = SupportReviewOpener.openURL
        SupportReviewOpener.openURL = { opened.append($0) }
        defer { SupportReviewOpener.openURL = original }
        let model = SupportThreadModel(id: "cv1")
        model.opener = SupportOfferOpener(queue: SupportOfferReceipts(defaults: defaults), send: { _ in nil })
        let c = try card()
        await model.openReview(c, generation: SupportAPI.shared.actionGeneration)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://apps.apple.com/app/id1234567890?action=write-review"])
        XCTAssertNil(model.opening)

        model.opener.send = { _ in throw AppReferSupportError(status: 409, message: "revoked") }
        await model.openReview(c, generation: SupportAPI.shared.actionGeneration)
        XCTAssertEqual(opened.count, 1, "a withdrawn card never opens the store")

        // Offline: the store page still opens (the receipt stays queued and is sent later).
        model.opener.send = { _ in throw URLError(.notConnectedToInternet) }
        await model.openReview(c, generation: SupportAPI.shared.actionGeneration)
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(model.opener.queue.pending.count, 1)

        // Unavailable cards and taps from before an account switch never open anything.
        model.opener.send = { _ in nil }
        await model.openReview(try card(#"{"cardId":"rvc_1","status":"unavailable","reason":"expired","store":null,"url":null}"#), generation: SupportAPI.shared.actionGeneration)
        await model.openReview(c, generation: SupportAPI.shared.actionGeneration - 1)
        XCTAssertEqual(opened.count, 2)

        // reset() drops pending receipts with the old session.
        SupportOfferReceipts.shared.enqueue(SupportOfferReceipt(conversationId: "cv1", cardId: "rvc_a", kind: "opened", clientEventId: "open_reset02", occurredAt: SupportOfferClock.iso(Date())))
        AppReferSupport.shared.dismissForReset()
        XCTAssertTrue(SupportOfferReceipts.shared.pending.isEmpty)
    }

    @MainActor
    func testCardViewRendersEveryStateInLightAndDark() throws {
        let palette = SupportPalette(Color(red: 0.47, green: 0.34, blue: 1))
        for json in [reviewJSON, #"{"cardId":"rvc_1","status":"unavailable","reason":"revoked","store":null,"url":null}"#,
                     #"{"cardId":"rvc_1","status":"unavailable","reason":"not_on_platform","store":null,"url":null}"#] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let host = UIHostingController(rootView: SupportReviewCardView(card: try card(json), palette: palette, opening: false, open: {}).frame(width: 340))
                host.overrideUserInterfaceStyle = style
                host.view.frame = CGRect(x: 0, y: 0, width: 340, height: 300)
                host.view.layoutIfNeeded()
                XCTAssertGreaterThan(host.view.intrinsicContentSize.height, 60)
            }
        }
    }
    #endif
}

#if os(iOS)
/// Opt-in screenshots of the review card in a chat, rendered on the Simulator from fixtures (no
/// network, no store call): `TEST_RUNNER_APPREFER_SUPPORT_SCREENSHOTS=/path xcodebuild test …`.
final class SupportReviewScreenshotTests: XCTestCase {
    @MainActor
    func testWritesReviewCardScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["APPREFER_SUPPORT_SCREENSHOTS"] else { throw XCTSkip("set APPREFER_SUPPORT_SCREENSHOTS") }
        guard #available(iOS 16, *) else { throw XCTSkip("ImageRenderer needs iOS 16") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let decode = { (json: String) in try JSONDecoder().decode(AppReferSupportMessage.self, from: Data(json.utf8)) }
        let customer = try decode(#"{"id":"m1","from":"customer","text":"That fixed it, sync works again.","createdAt":"2026-10-19T11:59:00.000Z","attachments":[]}"#)
        let team = try decode(#"{"id":"m2","from":"team","authorName":"Jay","text":"Great, glad it's working again!","createdAt":"2026-10-19T12:00:00.000Z","attachments":[]}"#)
        let palette = SupportPalette(Color(red: 0.47, green: 0.34, blue: 1))
        let open = try JSONDecoder().decode(AppReferSupportReviewCard.self, from: Data(reviewJSON.utf8))
        let gone = try JSONDecoder().decode(AppReferSupportReviewCard.self, from: Data(#"{"cardId":"rvc_1","status":"unavailable","reason":"revoked","store":null,"url":null}"#.utf8))
        for (name, card, style) in [("open-light", open, ColorScheme.light), ("open-dark", open, .dark), ("withdrawn-light", gone, .light)] {
            SupportStrings.forcedLanguage = "en"
            let chat = VStack(spacing: 10) {
                SupportCustomerBubble(message: customer, palette: palette, tail: true, view: { _ in })
                SupportTeamBubble(message: team, palette: palette, avatar: false, view: { _ in })
                SupportReviewCardView(card: card, palette: palette, opening: false, open: {})
                    .frame(maxWidth: 340, alignment: .leading).padding(.leading, 38).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14).frame(width: 390).background(SupportColors.background)
            .environment(\.colorScheme, style)
            let renderer = ImageRenderer(content: chat)
            renderer.scale = 2
            try XCTUnwrap(renderer.uiImage?.pngData()).write(to: URL(fileURLWithPath: directory).appendingPathComponent("ios-review-\(name).png"))
        }
        SupportStrings.forcedLanguage = nil
    }
}
#endif
