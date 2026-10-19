import XCTest
@testable import AppRefer
#if os(iOS)
import SwiftUI
import UIKit
#endif

/// Serves canned Support responses and records every request (offer cards).
private final class OfferStub: URLProtocol, @unchecked Sendable {
    enum Reply { case json(Int, String); case fail(URLError.Code) }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _requests: [(URLRequest, String)] = []
    private nonisolated(unsafe) static var _handler: ((URLRequest) -> Reply)?
    static var requests: [(URLRequest, String)] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func serve(_ handler: @escaping (URLRequest) -> Reply) { lock.lock(); _requests = []; _handler = handler; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = ""
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body += String(decoding: buffer[0..<n], as: UTF8.self) }
        }
        Self.lock.lock()
        Self._requests.append((request, body))
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

private let cardJSON = #"""
{"cardId":"ofc_0123456789abcdef01234567","offeringId":"main","packageId":null,"status":"available","reason":null,"eligibility":"checked",
 "packages":[{"id":"$ar_annual","packageType":"annual","displayName":null,"productId":"app.pro.annual","current":false},
             {"id":"$ar_monthly","packageType":"monthly","displayName":"Monthly Pro","productId":"app.pro.monthly","current":true}]}
"""#

final class SupportOfferTests: XCTestCase {
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

    private func card(_ json: String = cardJSON) throws -> AppReferSupportOfferCard {
        try JSONDecoder().decode(AppReferSupportOfferCard.self, from: Data(json.utf8))
    }

    private func api() async -> SupportAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfferStub.self]
        let storage = AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain())
        let api = SupportAPI(baseURL: "https://support.test", session: URLSession(configuration: config), deviceId: { nil },
                             userStorage: storage, tokenKeychain: FakeDeviceIdKeychain())
        await api.configure(apiKey: "pk_live_key")
        return api
    }
    private let session = #"{"session":"ars_one","created":true}"#
    private func isSession(_ r: URLRequest) -> Bool { r.url!.path == "/api/support/v1/session" }

    // MARK: Model

    func testDecodesCardsAndOldPayloadsWithoutThem() throws {
        let thread = """
        {"conversation":{"id":"cv1","subject":"Plans","status":"open","preview":"x","lastMessageAt":"2026-10-19T12:00:00.000Z","lastFrom":"team","unread":1},
         "messages":[{"id":"m1","from":"team","authorName":"Jay","text":"","createdAt":"2026-10-19T12:00:00.000Z","attachments":[],"offer":\(cardJSON)},
                     {"id":"m2","from":"team","authorName":"Jay","text":"Hi","createdAt":"2026-10-19T12:00:01.000Z","attachments":[]}],"persona":null}
        """
        let t = try JSONDecoder().decode(SupportThread.self, from: Data(thread.utf8))
        let offer = try XCTUnwrap(t.messages[0].offer)
        XCTAssertEqual(offer.offeringId, "main")
        XCTAssertTrue(offer.isAvailable)
        XCTAssertEqual(offer.packages.map(\.current), [false, true])
        XCTAssertNil(t.messages[1].offer)
    }

    func testLookFollowsServerStateAndHandler() throws {
        let c = try card()
        XCTAssertEqual(SupportOfferLook.of(c, hasHandler: true), .open)
        XCTAssertEqual(SupportOfferLook.of(c, hasHandler: false), .unsupported)
        XCTAssertEqual(SupportOfferLook.of(c, hasHandler: false).notice, "Update the app to open this")
        let owned = try card(cardJSON.replacingOccurrences(of: #""status":"available""#, with: #""status":"owned""#))
        XCTAssertEqual(SupportOfferLook.of(owned, hasHandler: true), .owned)
        let gone = try card(cardJSON.replacingOccurrences(of: #""status":"available""#, with: #""status":"unavailable""#))
        XCTAssertEqual(SupportOfferLook.of(gone, hasHandler: true), .unavailable)
        XCTAssertEqual(SupportOfferLook.of(gone, hasHandler: true).notice, "These options are no longer available")
        // An unknown future status is never drawn as an open card.
        let future = try card(cardJSON.replacingOccurrences(of: #""status":"available""#, with: #""status":"paused""#))
        XCTAssertEqual(SupportOfferLook.of(future, hasHandler: true), .unavailable)
    }

    func testPackageLabelsNeverInventAName() throws {
        let c = try card()
        XCTAssertEqual(SupportOfferText.label(c.packages[0], storeName: "Pro Yearly"), "Yearly")
        XCTAssertEqual(SupportOfferText.label(c.packages[1], storeName: nil), "Monthly Pro")
        let custom = AppReferSupportOfferCard.Package(id: "gold", packageType: "custom", displayName: nil, productId: "p", current: false)
        XCTAssertEqual(SupportOfferText.label(custom, storeName: "Gold Pack"), "Gold Pack")
        XCTAssertEqual(SupportOfferText.label(custom, storeName: nil), "Option")
        SupportStrings.forcedLanguage = "de"
        XCTAssertEqual(SupportOfferText.label(c.packages[0], storeName: nil), "Jährlich")
        XCTAssertEqual(SupportStrings.text("support.offer.open"), "Optionen ansehen")
    }

    /// Ordinary full-price cards never read like a deal, in any language.
    func testCardCopyIsNeutralInEveryLanguage() {
        let deal = ["offer", "angebot", "offre", "oferta", "offerta", "deal", "discount", "rabatt", "korting", "skidka", "скидк", "предложени", "オファー", "優惠", "优惠", "折扣", "할인", "割引"]
        for language in ["en", "de", "fr", "es", "it", "pt-BR", "nl", "ru", "ja", "ko", "zh-Hans", "zh-Hant"] {
            SupportStrings.forcedLanguage = language
            for key in ["support.offer.title", "support.offer.open", "support.offer.unavailable", "support.offer.unsupported", "support.offer.a11y.hint"] {
                let text = SupportStrings.text(key).lowercased()
                XCTAssertFalse(deal.contains { text.contains($0) }, "\(language) \(key): \(text)")
            }
        }
    }

    /// The price carries the store's own billing period; one-time purchases and unusual periods show the bare store price.
    func testPriceShowsTheStoresOwnPeriod() {
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "£29.99", name: nil, period: "P1Y")), "£29.99/year")
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "£4.99", name: nil, period: "P1M")), "£4.99/month")
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "£2.99", name: nil, period: "P7D")), "£2.99/week")
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "£9.99", name: nil, period: "P3M")), "£9.99 every 3 months")
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "£9.99", name: nil, period: "P12M")), "£9.99/year")
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "£4.99", name: nil, period: nil, oneTime: true)), "£4.99")
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "£1.99", name: nil, period: "P3D")), "£1.99")
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "£1.99", name: nil, period: "garbage")), "£1.99")
        XCTAssertEqual(SupportOfferText.periodKey("P2Y"), nil)
        SupportStrings.forcedLanguage = "de"
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "29,99 €", name: nil, period: "P1Y")), "29,99 €/Jahr")
        SupportStrings.forcedLanguage = "ja"
        XCTAssertEqual(SupportOfferText.price(SupportOfferPrice(price: "¥1,500", name: nil, period: "P6M")), "6か月ごとに¥1,500")
    }

    /// An owned subscription is the current plan; an owned one-off (credit pack, lifetime) is purchased.
    func testOwnedTagFitsWhatWasBought() {
        let sub = AppReferSupportOfferCard.Package(id: "$ar_annual", packageType: "annual", displayName: nil, productId: "p", current: true)
        let life = AppReferSupportOfferCard.Package(id: "$ar_lifetime", packageType: "lifetime", displayName: nil, productId: "l", current: true)
        let pack = AppReferSupportOfferCard.Package(id: "gold", packageType: "custom", displayName: nil, productId: "g", current: true)
        XCTAssertEqual(SupportOfferText.ownedTag(sub, price: SupportOfferPrice(price: "£29.99", name: nil, period: "P1Y")), "Current plan")
        XCTAssertEqual(SupportOfferText.ownedTag(sub, price: nil), "Current plan")
        XCTAssertEqual(SupportOfferText.ownedTag(life, price: nil), "Purchased")
        XCTAssertEqual(SupportOfferText.ownedTag(pack, price: SupportOfferPrice(price: "£4.99", name: nil, oneTime: true)), "Purchased")
        XCTAssertNil(SupportOfferText.ownedTag(AppReferSupportOfferCard.Package(id: "x", packageType: "monthly", displayName: nil, productId: "m", current: false), price: nil))
    }

    func testPickedPackageNarrowsTheRows() throws {
        let one = try card(cardJSON.replacingOccurrences(of: #""packageId":null"#, with: #""packageId":"$ar_annual""#))
        XCTAssertEqual(one.shownPackages.map(\.id), ["$ar_annual"])
        XCTAssertEqual(try card().shownPackages.count, 2)
    }

    // MARK: Receipts

    func testReceiptQueuePersistsDedupesAndDropsOldOrRetriedTooOften() {
        let q = SupportOfferReceipts(defaults: defaults)
        let now = SupportOfferClock.iso(Date())
        let a = SupportOfferReceipt(conversationId: "cv1", cardId: "ofc_a", kind: "shown", clientEventId: "shown_a", occurredAt: now)
        q.enqueue(a); q.enqueue(a)
        XCTAssertEqual(SupportOfferReceipts(defaults: defaults).pending, [a], "kept on disk, once per id")
        let old = SupportOfferReceipt(conversationId: "cv1", cardId: "ofc_b", kind: "opened", clientEventId: "open_old",
                                      occurredAt: SupportOfferClock.iso(Date().addingTimeInterval(-8 * 86400)))
        q.enqueue(old)
        XCTAssertEqual(q.pending, [a], "older than 7 days is dropped")
        for _ in 0..<(SupportOfferReceipts.maxAttempts - 1) { q.failed(a) }
        XCTAssertEqual(q.pending.first?.attempts, SupportOfferReceipts.maxAttempts - 1)
        q.failed(a)
        XCTAssertTrue(q.pending.isEmpty, "gives up after maxAttempts")
        for i in 0..<60 { q.enqueue(SupportOfferReceipt(conversationId: "cv1", cardId: "ofc_\(i)", kind: "opened", clientEventId: "open_\(i)", occurredAt: now)) }
        XCTAssertEqual(q.pending.count, SupportOfferReceipts.maxItems)
        q.clear()
        XCTAssertTrue(q.pending.isEmpty)
    }

    func testOpenerRecordsRefusesOrOpensOffline() async throws {
        let q = SupportOfferReceipts(defaults: defaults)
        let c = try card()
        var opener = SupportOfferOpener(queue: q, timeout: 2_000_000_000, send: { _ in nil })
        let r1 = opener.receipt(for: c, conversationId: "cv1")
        XCTAssertEqual(r1.kind, "opened")
        XCTAssertTrue(r1.clientEventId.hasPrefix("open_"))
        let o1 = await opener.check(r1)
        XCTAssertEqual(o1, .recorded(nil))
        XCTAssertTrue(q.pending.isEmpty)

        opener.send = { _ in throw AppReferSupportError(status: 409, message: "This offer can't be opened (revoked).") }
        let o2 = await opener.check(opener.receipt(for: c, conversationId: "cv1"))
        XCTAssertEqual(o2, .refused)
        XCTAssertTrue(q.pending.isEmpty, "a refusal is final")

        opener.send = { _ in throw URLError(.notConnectedToInternet) }
        let r3 = opener.receipt(for: c, conversationId: "cv1")
        let o3 = await opener.check(r3)
        XCTAssertEqual(o3, .offline)
        XCTAssertEqual(q.pending.map(\.clientEventId), [r3.clientEventId], "kept for later with the same id")

        opener.timeout = 50_000_000
        opener.send = { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return nil }
        let started = Date()
        let o4 = await opener.check(opener.receipt(for: c, conversationId: "cv1"))
        XCTAssertEqual(o4, .offline)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "never waits on a slow network")
        XCTAssertEqual(q.pending.count, 2)
    }

    func testShownReceiptIdIsStablePerCard() {
        XCTAssertEqual(supportOfferShownId("ofc_0123456789abcdef01234567"), "shown_0123456789abcdef01234567")
    }

    // MARK: API

    func testRequestsAnnounceCardsAndAskForThePlatformsProducts() async throws {
        OfferStub.serve { r in
            if self.isSession(r) { return .json(201, self.session) }
            if r.url!.path.hasSuffix("/offers") { return .json(200, #"{"offers":[\#(cardJSON),null]}"#) }
            return .json(200, #"{"conversation":{"id":"cv1","subject":"s","status":"open","preview":"p","lastMessageAt":"2026-10-19T12:00:00.000Z","lastFrom":"team","unread":0},"messages":[],"persona":null}"#)
        }
        let api = await api()
        SupportOfferHandlerFlag.shared.set(false)
        _ = try await api.thread("cv1", after: "2026-10-19T12:00:00.000Z")
        SupportOfferHandlerFlag.shared.set(true)
        let cards = try await api.offerCards("cv1")
        SupportOfferHandlerFlag.shared.set(false)
        XCTAssertEqual(cards.map(\.cardId), ["ofc_0123456789abcdef01234567"], "unreadable entries are skipped")
        let calls = OfferStub.requests.filter { !isSession($0.0) }
        XCTAssertEqual(calls[0].0.value(forHTTPHeaderField: "X-AppRefer-Support-Features"), "offers, reviews")
        let threadQuery = try XCTUnwrap(URLComponents(url: calls[0].0.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(threadQuery.first { $0.name == "platform" }?.value, "ios")
        XCTAssertEqual(threadQuery.first { $0.name == "after" }?.value, "2026-10-19T12:00:00.000Z")
        XCTAssertEqual(calls[1].0.url!.path, "/api/support/v1/conversations/cv1/offers")
        XCTAssertEqual(calls[1].0.url!.query, "platform=ios")
        XCTAssertEqual(calls[1].0.value(forHTTPHeaderField: "X-AppRefer-Support-Features"), "offers, offer-handler, reviews")
    }

    func testFlushSendsOnceKeepsTransientFailuresAndDropsRefusals() async throws {
        let q = SupportOfferReceipts(defaults: defaults)
        let now = SupportOfferClock.iso(Date())
        let ok = SupportOfferReceipt(conversationId: "cv1", cardId: "ofc_ok", kind: "shown", clientEventId: "shown_ok0001", occurredAt: now)
        let flaky = SupportOfferReceipt(conversationId: "cv1", cardId: "ofc_flaky", kind: "opened", clientEventId: "open_flaky01", occurredAt: now)
        let gone = SupportOfferReceipt(conversationId: "cv1", cardId: "ofc_gone", kind: "opened", clientEventId: "open_gone001", occurredAt: now)
        [ok, flaky, gone].forEach(q.enqueue)
        OfferStub.serve { r in
            if self.isSession(r) { return .json(201, self.session) }
            if r.url!.path.contains("ofc_flaky") { return .json(503, #"{"error":"busy"}"#) }
            if r.url!.path.contains("ofc_gone") { return .json(404, #"{"error":"Not found"}"#) }
            return .json(201, #"{"eventId":"ofe_x","duplicate":false,"offer":null}"#)
        }
        let api = await api()
        await api.flushOfferReceipts(q)
        XCTAssertEqual(q.pending.map(\.cardId), ["ofc_flaky"])
        XCTAssertEqual(q.pending.first?.attempts, 1)
        let sent = OfferStub.requests.filter { $0.0.url!.path.contains("ofc_ok") }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent[0].1.utf8)) as? [String: String])
        XCTAssertEqual(body, ["kind": "shown", "clientEventId": "shown_ok0001", "occurredAt": now])
    }

    #if os(iOS)
    @MainActor
    func testOnOfferIsAnnouncedAndDeliveredAndResetClearsReceipts() throws {
        let support = AppReferSupport.shared
        defer { support.onOffer = nil }
        XCTAssertFalse(support.deliver(AppReferSupportOffer(cardId: "ofc_a", conversationId: "cv1", offeringId: "main", packageId: nil)),
                       "no handler: nothing opens")
        var got: [AppReferSupportOffer] = []
        support.onOffer = { got.append($0) }
        XCTAssertTrue(SupportOfferHandlerFlag.shared.isSet)
        let offer = AppReferSupportOffer(cardId: "ofc_a", conversationId: "cv1", offeringId: "main", packageId: "$ar_annual")
        XCTAssertTrue(support.deliver(offer))
        XCTAssertEqual(got, [offer])
        support.onOffer = nil
        XCTAssertFalse(SupportOfferHandlerFlag.shared.isSet)

        SupportOfferReceipts.shared.enqueue(SupportOfferReceipt(conversationId: "cv1", cardId: "ofc_a", kind: "opened", clientEventId: "open_reset01", occurredAt: SupportOfferClock.iso(Date())))
        support.dismissForReset()
        XCTAssertTrue(SupportOfferReceipts.shared.pending.isEmpty, "receipts never outlive the session they belong to")
    }

    @MainActor
    func testTappingAnOpenCardHandsItToTheAppAndARefusalDoesNot() async throws {
        let support = AppReferSupport.shared
        var got: [AppReferSupportOffer] = []
        support.onOffer = { got.append($0) }
        defer { support.onOffer = nil }
        let c = try card()
        let model = SupportThreadModel(id: "cv1")
        model.opener = SupportOfferOpener(queue: SupportOfferReceipts(defaults: defaults), send: { _ in nil })
        await model.open(c, generation: SupportAPI.shared.actionGeneration)
        XCTAssertEqual(got.map(\.offeringId), ["main"])
        XCTAssertNil(model.opening)

        model.opener.send = { _ in throw AppReferSupportError(status: 409, message: "revoked") }
        await model.open(c, generation: SupportAPI.shared.actionGeneration)
        XCTAssertEqual(got.count, 1, "a withdrawn card never opens the paywall")

        // Disabled cards and a missing handler never reach the app.
        let owned = try card(cardJSON.replacingOccurrences(of: #""status":"available""#, with: #""status":"owned""#))
        model.opener.send = { _ in nil }
        await model.open(owned, generation: SupportAPI.shared.actionGeneration)
        support.onOffer = nil
        await model.open(c, generation: SupportAPI.shared.actionGeneration)
        XCTAssertEqual(got.count, 1)
        // A tap from before an account switch is dropped.
        support.onOffer = { got.append($0) }
        await model.open(c, generation: SupportAPI.shared.actionGeneration - 1)
        XCTAssertEqual(got.count, 1)
    }

    @MainActor
    func testCardViewRendersEveryStateInLightAndDark() throws {
        let c = try card()
        let palette = SupportPalette(Color(red: 0.47, green: 0.34, blue: 1))
        for status in ["available", "owned", "unavailable"] {
            let state = try card(cardJSON.replacingOccurrences(of: #""status":"available""#, with: #""status":"\#(status)""#))
            for style in [UIUserInterfaceStyle.light, .dark] {
                for handler in [true, false] {
                    let view = SupportOfferCardView(card: state, prices: ["$ar_annual": SupportOfferPrice(price: "£29.99", name: nil)],
                                                    palette: palette, hasHandler: handler, opening: false, open: {})
                    let host = UIHostingController(rootView: view.frame(width: 340))
                    host.overrideUserInterfaceStyle = style
                    host.view.frame = CGRect(x: 0, y: 0, width: 340, height: 300)
                    host.view.layoutIfNeeded()
                    XCTAssertGreaterThan(host.view.intrinsicContentSize.height, 80, "\(status) \(style.rawValue) \(handler)")
                }
            }
        }
        _ = c
    }
    #endif
}

#if os(iOS)
/// Opt-in screenshots of the offer card in a chat, rendered on the Simulator from fixtures (no
/// network): `TEST_RUNNER_APPREFER_SUPPORT_SCREENSHOTS=/path xcodebuild test …`.
final class SupportOfferScreenshotTests: XCTestCase {
    @MainActor
    func testWritesOfferCardScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["APPREFER_SUPPORT_SCREENSHOTS"] else { throw XCTSkip("set APPREFER_SUPPORT_SCREENSHOTS") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let decode = { (json: String) in try JSONDecoder().decode(AppReferSupportMessage.self, from: Data(json.utf8)) }
        let customer = try decode(#"{"id":"m1","from":"customer","text":"Is there a yearly plan? Monthly adds up.","createdAt":"2026-10-19T11:59:00.000Z","attachments":[]}"#)
        let team = try decode(#"{"id":"m2","from":"team","authorName":"Jay","text":"Yes! Yearly works out cheaper. Here are both plans:","createdAt":"2026-10-19T12:00:00.000Z","attachments":[]}"#)
        let base = try JSONDecoder().decode(AppReferSupportOfferCard.self, from: Data(cardJSON.utf8))
        let state = { (status: String) in try JSONDecoder().decode(AppReferSupportOfferCard.self, from: Data(cardJSON.replacingOccurrences(of: #""status":"available""#, with: #""status":"\#(status)""#).utf8)) }
        let prices = ["$ar_annual": SupportOfferPrice(price: "£29.99", name: nil, period: "P1Y"), "$ar_monthly": SupportOfferPrice(price: "£4.99", name: nil, period: "P1M")]
        let palette = SupportPalette(Color(red: 0.47, green: 0.34, blue: 1))
        let cases: [(String, AppReferSupportOfferCard, Bool, UIUserInterfaceStyle)] = [
            ("open-light", base, true, .light), ("open-dark", base, true, .dark),
            ("unsupported-light", base, false, .light), ("owned-dark", try state("owned"), true, .dark),
            ("unavailable-light", try state("unavailable"), true, .light),
        ]
        for (name, card, handler, style) in cases {
            let chat = VStack(spacing: 10) {
                SupportCustomerBubble(message: customer, palette: palette, tail: true, view: { _ in })
                SupportTeamBubble(message: team, palette: palette, avatar: false, view: { _ in })
                SupportOfferCardView(card: card, prices: prices, palette: palette, hasHandler: handler, opening: false, open: {})
                    .frame(maxWidth: 340, alignment: .leading).padding(.leading, 38).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14).frame(width: 390).background(SupportColors.background)
            .environment(\.colorScheme, style == .dark ? .dark : .light)
            guard #available(iOS 16, *) else { throw XCTSkip("ImageRenderer needs iOS 16") }
            let renderer = ImageRenderer(content: chat)
            renderer.scale = 2
            try XCTUnwrap(renderer.uiImage?.pngData()).write(to: URL(fileURLWithPath: directory).appendingPathComponent("ios-offer-\(name).png"))
        }
    }
}
#endif
