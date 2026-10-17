import XCTest
@testable import AppRefer

/// Serves canned help-centre and status responses and records every request.
private final class HelpStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body = "{}"; var headers: [String: String] = [:] }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _requests: [URLRequest] = []
    private nonisolated(unsafe) static var _handler: ((URLRequest) -> Reply?)?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func serve(_ handler: @escaping (URLRequest) -> Reply?) { lock.lock(); _requests = []; _handler = handler; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let handler = Self._handler
        Self.lock.unlock()
        guard let reply = handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

final class SupportHelpTests: XCTestCase {
    private let listJSON = """
    {"articles":[{"slug":"refunds","title":"Refunds","summary":"How refunds work","category":"Billing","locale":"de","url":"https://help.example.com/refunds","status":"published","updatedAt":"2026-10-15T09:00:00.000Z"},
                 {"slug":"draft-1","title":"Coming soon","summary":"","category":null,"locale":null,"url":null,"status":"draft","updatedAt":"2026-10-16T09:00:00Z"}],"locale":"de"}
    """
    private let statusJSON = """
    {"push":{"ios":{"configured":true,"verified":true,"checkedAt":"2026-10-16T09:00:00.000Z","environments":{"production":true,"sandbox":true}},
             "android":{"configured":true,"verified":false,"checkedAt":"2026-10-16T09:00:00.000Z","error":"No permission"}},
     "email":{"configured":true,"verified":null,"receivesReplies":true},"helpCentre":{"publishedArticles":12}}
    """

    private func api(_ clock: Clock = Clock(), key: String? = "pk_test_help") async -> SupportAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HelpStub.self]
        let api = SupportAPI(baseURL: "https://help.test", session: URLSession(configuration: config),
                             deviceId: { nil }, userStorage: AppReferStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeDeviceIdKeychain()),
                             tokenKeychain: FakeDeviceIdKeychain(), now: { clock.now })
        if let key { await api.configure(apiKey: key) }
        return api
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private func articleRequests() -> [URLRequest] { HelpStub.requests.filter { $0.url!.path.hasPrefix("/api/support/v1/articles") } }

    // MARK: - Articles

    func testListSendsKeyLocaleAndQueryWithoutASession() async throws {
        HelpStub.serve { _ in .init(body: self.listJSON) }
        let api = await api()
        let articles = try await api.helpArticleList(query: "  c++ & refunds ", language: "pt-BR")
        XCTAssertEqual(articles.map(\.slug), ["refunds", "draft-1"])
        let request = try XCTUnwrap(articleRequests().last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/support/v1/articles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AppRefer-Key"), "pk_test_help")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-AppRefer-Support-Session"), "the help centre needs no session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "pt-BR")
        XCTAssertEqual(query(request)["locale"], "pt-BR")
        XCTAssertEqual(query(request)["q"], "c++ & refunds", "trimmed, and + and & survive encoding")
        XCTAssertTrue(request.url!.absoluteString.contains("q=c%2B%2B%20%26%20refunds"))
        XCTAssertFalse(HelpStub.requests.contains { $0.url!.path.hasSuffix("/session") }, "no support session is minted")
    }

    func testListWithoutQueryHasNoQParameterAndLongQueriesAreCut() async throws {
        HelpStub.serve { _ in .init(body: self.listJSON) }
        let api = await api()
        _ = try await api.helpArticleList(query: "   ", language: "en")
        XCTAssertNil(query(articleRequests().last!)["q"])
        _ = try await api.helpArticleList(query: String(repeating: "a", count: 250), language: "en")
        XCTAssertEqual(query(articleRequests().last!)["q"]?.count, 200)
    }

    func testDecodesArticlesAndDrafts() async throws {
        HelpStub.serve { _ in .init(body: self.listJSON) }
        let articles = try await api().helpArticleList(query: nil, language: "de")
        XCTAssertEqual(articles[0].category, "Billing")
        XCTAssertEqual(articles[0].webURL?.host, "help.example.com")
        XCTAssertNotNil(articles[0].updatedDate)
        XCTAssertFalse(articles[0].isDraft)
        XCTAssertTrue(articles[1].isDraft)
        XCTAssertNil(articles[1].category)
        XCTAssertNil(articles[1].webURL)
    }

    func testListIsCachedForFiveMinutesThenRefetched() async throws {
        HelpStub.serve { _ in .init(body: self.listJSON) }
        let clock = Clock()
        let api = await api(clock)
        _ = try await api.helpArticleList(query: nil, language: "en")
        clock.advance(299)
        _ = try await api.helpArticleList(query: nil, language: "en")
        XCTAssertEqual(articleRequests().count, 1, "served from memory")
        _ = try await api.helpArticleList(query: nil, language: "de")
        XCTAssertEqual(articleRequests().count, 2, "another language is another list")
        clock.advance(2)
        _ = try await api.helpArticleList(query: nil, language: "en")
        XCTAssertEqual(articleRequests().count, 3, "refetched after five minutes")
    }

    func testOfflineReturnsTheLastListAndOtherwiseThrows() async throws {
        HelpStub.serve { _ in .init(body: self.listJSON) }
        let clock = Clock()
        let api = await api(clock)
        _ = try await api.helpArticleList(query: nil, language: "en")
        clock.advance(3600)
        HelpStub.serve { _ in nil } // offline
        let stale = try await api.helpArticleList(query: nil, language: "en")
        XCTAssertEqual(stale.count, 2, "an old list beats an error")
        let cached = await api.cachedHelpArticleList(language: "en")
        XCTAssertEqual(cached?.count, 2)
        do {
            _ = try await api.helpArticleList(query: nil, language: "fr")
            XCTFail("nothing cached for fr")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testArticleDecodesBodyAndThrowsNotFoundFor404() async throws {
        HelpStub.serve { request in
            if request.url!.path.hasSuffix("/missing") { return .init(status: 404, body: #"{"error":"Article not found"}"#) }
            return .init(body: ##"{"article":{"slug":"a b","title":"Refunds","summary":"s","category":null,"locale":"en","url":null,"status":"published","updatedAt":"2026-10-15T09:00:00Z","body":"# Refunds\n\nText"}}"##)
        }
        let api = await api()
        let article = try await api.helpArticle(slug: "a b", language: "en")
        XCTAssertEqual(article.title, "Refunds")
        XCTAssertEqual(article.body, "# Refunds\n\nText")
        let request = try XCTUnwrap(articleRequests().last)
        XCTAssertEqual(request.url?.absoluteString, "https://help.test/api/support/v1/articles/a%20b?locale=en")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AppRefer-Key"), "pk_test_help")
        do {
            _ = try await api.helpArticle(slug: "missing", language: "en")
            XCTFail("404 must throw")
        } catch let error as AppReferSupportError {
            XCTAssertTrue(error.isNotFound)
            XCTAssertEqual(error.status, 404)
        }
    }

    func testWithoutAnApiKeyTheHelpCentreIsUnavailable() async {
        HelpStub.serve { _ in .init(body: self.listJSON) }
        let api = await api(key: nil)
        // Only when AppRefer itself isn't configured in this test process.
        guard AppRefer.currentApiKey() == nil else { return }
        do {
            _ = try await api.helpArticleList(query: nil, language: "en")
            XCTFail("expected unavailable")
        } catch let error as AppReferSupportError {
            XCTAssertEqual(error.status, 0)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(articleRequests().isEmpty)
    }

    // MARK: - Status

    func testStatusMapping() throws {
        let status = try JSONDecoder().decode(AppReferSupportStatus.self, from: Data(statusJSON.utf8))
        XCTAssertTrue(status.pushReady)
        XCTAssertTrue(status.emailReplies)
        XCTAssertEqual(status.helpCentreArticles, 12)
        XCTAssertEqual(status.push.android.verified, false)
        XCTAssertEqual(status.push.android.error, "No permission")
        XCTAssertNil(status.email.verified)
        XCTAssertEqual(status.push.ios.environments?.sandbox, true)
        // Missing sections decode as off.
        let empty = try JSONDecoder().decode(AppReferSupportStatus.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.pushReady)
        XCTAssertFalse(empty.emailReplies)
        XCTAssertEqual(empty.helpCentreArticles, 0)
    }

    func testPushReadyTruthTable() {
        func status(_ configured: Bool, _ verified: Bool?, production: Bool? = nil, sandbox: Bool? = nil) -> AppReferSupportStatus {
            let env = production == nil && sandbox == nil ? nil : AppReferSupportStatus.Environments(production: production, sandbox: sandbox)
            return AppReferSupportStatus(
                push: .init(ios: .init(configured: configured, verified: verified, environments: env), android: .init(configured: true, verified: true)),
                email: .init(configured: false, receivesReplies: false), helpCentreArticles: 0)
        }
        XCTAssertTrue(status(true, true).pushReady)
        XCTAssertFalse(status(true, false).pushReady)
        XCTAssertFalse(status(true, nil).pushReady, "not checked yet")
        XCTAssertFalse(status(false, nil).pushReady)
        XCTAssertFalse(status(false, true).pushReady)
        XCTAssertTrue(status(true, true, production: true, sandbox: true).pushReady)
        XCTAssertTrue(status(true, true, production: nil, sandbox: nil).pushReady, "unknown environments don't block")
        // The environment this build pushes to (from its signing; the Simulator is sandbox).
        let rejectedHere = SupportAPI.pushSandbox ? status(true, true, production: true, sandbox: false) : status(true, true, production: false, sandbox: true)
        let rejectedElsewhere = SupportAPI.pushSandbox ? status(true, true, production: false, sandbox: true) : status(true, true, production: true, sandbox: false)
        XCTAssertFalse(rejectedHere.pushReady)
        XCTAssertTrue(rejectedElsewhere.pushReady)
        // Android being ready never makes iOS ready.
        XCTAssertFalse(status(false, nil).pushReady)
    }

    func testStatusHonoursCacheControl() async throws {
        var maxAge = 300
        HelpStub.serve { _ in .init(body: self.statusJSON, headers: ["Cache-Control": "private, max-age=\(maxAge)"]) }
        let clock = Clock()
        let api = await api(clock)
        _ = try await api.supportStatus()
        clock.advance(299)
        _ = try await api.supportStatus()
        let statusCalls = { HelpStub.requests.filter { $0.url!.path == "/api/support/v1/status" } }
        XCTAssertEqual(statusCalls().count, 1)
        XCTAssertEqual(statusCalls().first?.value(forHTTPHeaderField: "X-AppRefer-Key"), "pk_test_help")
        clock.advance(2)
        maxAge = 30
        _ = try await api.supportStatus()
        XCTAssertEqual(statusCalls().count, 2)
        clock.advance(29)
        _ = try await api.supportStatus()
        XCTAssertEqual(statusCalls().count, 2, "30 s while something is unverified")
        clock.advance(2)
        _ = try await api.supportStatus()
        XCTAssertEqual(statusCalls().count, 3)
    }

    func testMaxAgeParsing() {
        XCTAssertEqual(SupportAPI.maxAge("private, max-age=300"), 300)
        XCTAssertEqual(SupportAPI.maxAge("max-age=30"), 30)
        XCTAssertEqual(SupportAPI.maxAge("max-age=99999"), 300, "capped at five minutes")
        XCTAssertEqual(SupportAPI.maxAge("no-store"), 0)
        XCTAssertNil(SupportAPI.maxAge("private"))
        XCTAssertNil(SupportAPI.maxAge(nil))
    }

    // MARK: - Markdown

    private func plain(_ s: AttributedString) -> String { String(s.characters) }
    private func links(_ s: AttributedString) -> [String] { s.runs.compactMap { $0.link?.absoluteString } }

    func testUnsafeLinksAreDropped() {
        let text = SupportMarkdown.inline("[a](javascript:alert(1)) [b](https://ok.example/x) [c](mailto:help@example.com) [d](data:text/html,hi) [e](/relative) [f](myapp://open) [g](JAVASCRIPT:alert(1)) <javascript:alert(2)> [h](http:no-host)")
        XCTAssertEqual(links(text), ["https://ok.example/x", "mailto:help@example.com"])
        XCTAssertTrue(plain(text).contains("a"), "the link text stays as plain text")
    }

    func testSafeURL() {
        XCTAssertNotNil(SupportMarkdown.safeURL("https://example.com"))
        XCTAssertNotNil(SupportMarkdown.safeURL("HTTP://example.com/a?b=c"))
        XCTAssertNotNil(SupportMarkdown.safeURL("mailto:a@b.co"))
        XCTAssertNil(SupportMarkdown.safeURL("mailto:"))
        XCTAssertNil(SupportMarkdown.safeURL("javascript:alert(1)"))
        XCTAssertNil(SupportMarkdown.safeURL("file:///etc/passwd"))
        XCTAssertNil(SupportMarkdown.safeURL("tel:123"))
        XCTAssertNil(SupportMarkdown.safeURL("//example.com"))
    }

    func testHTMLIsNeverKept() {
        let text = plain(SupportMarkdown.inline("Hi <script>alert('x')</script><b>there</b> <img src=x onerror=alert(1)> `<div>` <https://example.com>"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("<b>"))
        XCTAssertFalse(text.contains("onerror"))
        XCTAssertTrue(text.contains("there"))
        XCTAssertTrue(text.contains("<div>"), "code spans keep their text")
        XCTAssertTrue(text.contains("example.com"), "autolinks survive")
        let unclosed = plain(SupportMarkdown.inline("Before <script>steal()"))
        XCTAssertFalse(unclosed.contains("steal"))
    }

    func testInlineStyles() {
        let text = SupportMarkdown.inline("**bold** *it* `code` ~~gone~~")
        XCTAssertEqual(plain(text), "bold it code gone")
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertTrue(intents.contains { $0.contains(.stronglyEmphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.emphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.code) })
    }

    func testBlocks() {
        let md = """
        # Title #
        Intro line one
        continues here.

        ## Steps
        1. Open **Settings**
        2. Tap [Restore](https://example.com/restore)
           and wait
        - Top
          - Nested
        * [ ] todo

        > A quote
        > over two lines

        ```
        let x = "<b>"
        ```
        ---
        ![Screen](https://example.com/s.png "Title")
        ![Bad](javascript:alert(1))
        Setext
        ======
        """
        let blocks = SupportMarkdown.blocks(md)
        guard blocks.count == 14 else { return XCTFail("\(blocks.count) blocks: \(blocks)") }
        XCTAssertEqual(blocks[0], .heading(level: 1, text: AttributedString("Title")))
        if case let .paragraph(text) = blocks[1] { XCTAssertEqual(plain(text), "Intro line one continues here.") } else { XCTFail("\(blocks[1])") }
        if case .heading(2, _) = blocks[2] {} else { XCTFail("\(blocks[2])") }
        if case let .listItem(number, depth, text) = blocks[3] { XCTAssertEqual(number, 1); XCTAssertEqual(depth, 0); XCTAssertEqual(plain(text), "Open Settings") } else { XCTFail("\(blocks[3])") }
        if case let .listItem(number, _, text) = blocks[4] {
            XCTAssertEqual(number, 2)
            XCTAssertEqual(plain(text), "Tap Restore and wait", "indented continuation joins the item")
            XCTAssertEqual(links(text), ["https://example.com/restore"])
        } else { XCTFail("\(blocks[4])") }
        if case let .listItem(nil, depth, _) = blocks[5] { XCTAssertEqual(depth, 0) } else { XCTFail("\(blocks[5])") }
        if case let .listItem(nil, depth, _) = blocks[6] { XCTAssertEqual(depth, 1) } else { XCTFail("\(blocks[6])") }
        if case let .listItem(nil, _, text) = blocks[7] { XCTAssertTrue(plain(text).hasPrefix("☐")) } else { XCTFail("\(blocks[7])") }
        if case let .quote(text) = blocks[8] { XCTAssertEqual(plain(text), "A quote over two lines") } else { XCTFail("\(blocks[8])") }
        XCTAssertEqual(blocks[9], .code("let x = \"<b>\""))
        XCTAssertEqual(blocks[10], .rule)
        XCTAssertEqual(blocks[11], .image(url: URL(string: "https://example.com/s.png")!, alt: "Screen"))
        if case let .paragraph(text) = blocks[12] { XCTAssertEqual(plain(text), "Bad") } else { XCTFail("unsafe image becomes its alt text: \(blocks[12])") }
        XCTAssertEqual(blocks[13], .heading(level: 1, text: AttributedString("Setext")))
    }

    func testSetextAndEmptyInput() {
        XCTAssertEqual(SupportMarkdown.blocks(""), [])
        XCTAssertEqual(SupportMarkdown.blocks("Big\n==="), [.heading(level: 1, text: AttributedString("Big"))])
        XCTAssertEqual(SupportMarkdown.blocks("Small\n---"), [.heading(level: 2, text: AttributedString("Small"))])
        XCTAssertEqual(SupportMarkdown.blocks("***"), [.rule])
        XCTAssertEqual(SupportMarkdown.blocks("#hashtag").count, 1, "no space: not a heading")
        if case .paragraph = SupportMarkdown.blocks("#hashtag")[0] {} else { XCTFail() }
    }

    // MARK: - Strings

    func testNewKeysAreInEveryLanguage() {
        let keys = [
            "support.help.title", "support.help.search.placeholder", "support.help.search.noResults", "support.help.search.noResultsHint",
            "support.help.searching", "support.help.seeAll", "support.help.loading", "support.help.loadFailed", "support.help.listFailed",
            "support.help.updated", "support.help.draft", "support.help.otherCategory", "support.help.stillNeedHelp", "support.help.messageUs",
            "support.help.prompt", "support.help.openInBrowser", "support.help.a11y.clearSearch", "support.help.a11y.article",
            "support.status.sentNoticeEmail", "support.status.sentNoticeEmailNoTime", "support.status.sentNoticeInApp", "support.status.sentNoticeInAppNoTime",
        ]
        for language in SupportStrings.supportedLanguages {
            let table = SupportStrings.table(language)
            for key in keys {
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(language): \(key)")
            }
            XCTAssertTrue(table["support.help.search.noResults"]?.contains("{query}") ?? false, language)
            XCTAssertTrue(table["support.help.updated"]?.contains("{date}") ?? false, language)
        }
        defer { SupportStrings.forcedLanguage = nil }
        SupportStrings.forcedLanguage = "de"
        XCTAssertEqual(SupportStrings.text("support.help.search.noResults", ["query": "Abo"]), "Keine Artikel zu „Abo“")
    }
}

#if os(iOS)
@MainActor
final class SupportHelpUITests: XCTestCase {
    private func article(_ slug: String, _ category: String?) -> AppReferHelpArticle {
        AppReferHelpArticle(slug: slug, title: slug.capitalized, summary: "About \(slug)", category: category)
    }

    func testHelpSectionIsHiddenWithoutArticles() async {
        let model = SupportHomeModel()
        XCTAssertTrue(model.articles.isEmpty)
        defer { SupportStrings.forcedLanguage = nil }
        SupportStrings.forcedLanguage = "fi" // nothing cached for this language
        await model.refreshArticles()
        XCTAssertTrue(model.articles.isEmpty, "a failed load shows no section and no error")
        XCTAssertNil(model.error)
    }

    func testHelpSectionShowsCachedArticles() async {
        defer { SupportStrings.forcedLanguage = nil }
        SupportStrings.forcedLanguage = "sv"
        await SupportAPI.shared.seedHelp(language: "sv", articles: [article("refunds", "Billing")])
        let model = SupportHomeModel()
        await model.refreshArticles()
        XCTAssertEqual(model.articles.map(\.slug), ["refunds"])
    }

    func testGroupsByCategoryWithLooseArticlesLast() {
        let groups = SupportHelpModel.groups([article("a", "Billing"), article("b", nil), article("c", "Account"), article("d", "Billing")])
        XCTAssertEqual(groups.map(\.title), ["Billing", "Account", SupportStrings.text("support.help.otherCategory")])
        XCTAssertEqual(groups[0].articles.map(\.slug), ["a", "d"])
        XCTAssertEqual(SupportHelpModel.groups([article("x", nil)]).map(\.title), [nil], "no heading when nothing has a category")
    }

    func testLocalSearchMatchesEveryWordIgnoringCaseAndAccents() {
        let list = [AppReferHelpArticle(slug: "1", title: "Café refunds", summary: "Money back"), AppReferHelpArticle(slug: "2", title: "Login", summary: "Password reset")]
        XCTAssertEqual(SupportHelpModel.localMatches(list, "cafe MONEY").map(\.slug), ["1"])
        XCTAssertEqual(SupportHelpModel.localMatches(list, "reset").map(\.slug), ["2"])
        XCTAssertTrue(SupportHelpModel.localMatches(list, "nothing").isEmpty)
    }

    func testReplyNoticeFollowsStatus() throws {
        func status(push: Bool, email: Bool) -> AppReferSupportStatus {
            AppReferSupportStatus(push: .init(ios: .init(configured: push, verified: push ? true : nil), android: .init(configured: false, verified: nil)),
                                  email: .init(configured: email, receivesReplies: email), helpCentreArticles: 0)
        }
        XCTAssertEqual(SupportReplyNotice.choose(status: nil, hasPushToken: false, hasEmail: false), .push, "unknown keeps the old line")
        XCTAssertEqual(SupportReplyNotice.choose(status: status(push: true, email: true), hasPushToken: true, hasEmail: true), .push)
        XCTAssertEqual(SupportReplyNotice.choose(status: status(push: true, email: true), hasPushToken: false, hasEmail: true), .email, "the app never registered for push")
        XCTAssertEqual(SupportReplyNotice.choose(status: status(push: false, email: true), hasPushToken: true, hasEmail: true), .email)
        XCTAssertEqual(SupportReplyNotice.choose(status: status(push: false, email: true), hasPushToken: true, hasEmail: false), .inApp)
        XCTAssertEqual(SupportReplyNotice.choose(status: status(push: false, email: false), hasPushToken: false, hasEmail: true), .inApp)
        XCTAssertEqual(SupportReplyNotice.email.text(nil), SupportStrings.text("support.status.sentNoticeEmailNoTime"))
    }
}
#endif
