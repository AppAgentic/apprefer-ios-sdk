import Foundation

// MARK: - Help centre models

/// A help article as listed in the help centre (no body).
public struct AppReferHelpArticle: Identifiable, Hashable, Sendable, Decodable {
    public let slug: String
    public let title: String
    /// The article's summary, or the start of its text.
    public let summary: String
    public let category: String?
    /// The article's web page, if it has one.
    public let url: String?
    /// ISO 8601.
    public let updatedAt: String
    /// "published" or, for test SDK keys only, "draft".
    public let status: String?
    /// The translation the server picked (e.g. "de"), nil for the default language.
    public let locale: String?

    public var id: String { slug }
    public var isDraft: Bool { status == "draft" }
    public var updatedDate: Date? { SupportDates.parse(updatedAt) }
    /// `url` when it is an http(s) link.
    public var webURL: URL? { url.flatMap(SupportMarkdown.safeURL).flatMap { $0.scheme == "mailto" ? nil : $0 } }

    public init(slug: String, title: String, summary: String = "", category: String? = nil, url: String? = nil,
                updatedAt: String = "", status: String? = "published", locale: String? = nil) {
        self.slug = slug; self.title = title; self.summary = summary; self.category = category
        self.url = url; self.updatedAt = updatedAt; self.status = status; self.locale = locale
    }

    private enum CodingKeys: String, CodingKey { case slug, title, summary, category, url, updatedAt, status, locale }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? slug
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category).flatMap { $0.isEmpty ? nil : $0 }
        url = try c.decodeIfPresent(String.self, forKey: .url)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
    }
}

/// One help article with its markdown body.
public struct AppReferHelpArticleDetail: Identifiable, Hashable, Sendable, Decodable {
    public let article: AppReferHelpArticle
    /// Markdown. The built-in reader renders headings, lists, links, emphasis, code and
    /// images; HTML is never run and only http(s) and mailto links are kept.
    public let body: String

    public var id: String { article.slug }
    public var slug: String { article.slug }
    public var title: String { article.title }
    public var summary: String { article.summary }
    public var category: String? { article.category }
    public var url: String? { article.url }
    public var updatedAt: String { article.updatedAt }
    public var isDraft: Bool { article.isDraft }

    public init(article: AppReferHelpArticle, body: String) { self.article = article; self.body = body }

    private enum CodingKeys: String, CodingKey { case body }
    public init(from decoder: Decoder) throws {
        article = try AppReferHelpArticle(from: decoder)
        body = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .body) ?? ""
    }
}

/// What AppRefer Support can do for this app right now (`AppRefer.support.status()`).
public struct AppReferSupportStatus: Hashable, Sendable, Decodable {
    public struct Environments: Hashable, Sendable, Decodable {
        public let production: Bool?
        public let sandbox: Bool?
    }

    public struct PushChannel: Hashable, Sendable, Decodable {
        public let configured: Bool
        /// true: the store accepted the credentials; false: it rejected them (see `error`);
        /// nil: not configured or not checked yet (or the store was unreachable).
        public let verified: Bool?
        public let checkedAt: String?
        public let error: String?
        /// iOS only: which APNs environments accepted the key.
        public let environments: Environments?

        public init(configured: Bool, verified: Bool?, checkedAt: String? = nil, error: String? = nil, environments: Environments? = nil) {
            self.configured = configured; self.verified = verified; self.checkedAt = checkedAt; self.error = error; self.environments = environments
        }

        private enum CodingKeys: String, CodingKey { case configured, verified, checkedAt, error, environments }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
            verified = try c.decodeIfPresent(Bool.self, forKey: .verified)
            checkedAt = try c.decodeIfPresent(String.self, forKey: .checkedAt)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            environments = try c.decodeIfPresent(Environments.self, forKey: .environments)
        }

        static let off = PushChannel(configured: false, verified: nil)
    }

    public struct Push: Hashable, Sendable, Decodable {
        public let ios: PushChannel
        public let android: PushChannel
        private enum CodingKeys: String, CodingKey { case ios, android }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ios = try c.decodeIfPresent(PushChannel.self, forKey: .ios) ?? .off
            android = try c.decodeIfPresent(PushChannel.self, forKey: .android) ?? .off
        }
        public init(ios: PushChannel, android: PushChannel) { self.ios = ios; self.android = android }
    }

    public struct Email: Hashable, Sendable, Decodable {
        /// Replies can be emailed to customers who gave an email address.
        public let configured: Bool
        public let verified: Bool?
        /// Customers can answer those emails and their answer lands in the conversation.
        public let receivesReplies: Bool
        private enum CodingKeys: String, CodingKey { case configured, verified, receivesReplies }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
            verified = try c.decodeIfPresent(Bool.self, forKey: .verified)
            receivesReplies = try c.decodeIfPresent(Bool.self, forKey: .receivesReplies) ?? false
        }
        public init(configured: Bool, verified: Bool? = nil, receivesReplies: Bool) {
            self.configured = configured; self.verified = verified; self.receivesReplies = receivesReplies
        }
    }

    public let push: Push
    public let email: Email
    /// Published help articles (drafts not counted).
    public let helpCentreArticles: Int

    /// Register for reply notifications only when this is true: push is configured for
    /// iOS and Apple accepted the key (`verified == true`), and the APNs environment this
    /// build registers tokens for (`AppRefer.support.effectivePushEnvironment`: from the app's
    /// signing, or the app's explicit choice) wasn't rejected.
    public var pushReady: Bool { pushReady(for: PushEnvironmentSetting.shared.effective) }

    func pushReady(for environment: AppReferPushEnvironment) -> Bool {
        guard push.ios.configured, push.ios.verified == true else { return false }
        let accepted = environment == .sandbox ? push.ios.environments?.sandbox : push.ios.environments?.production
        return accepted != false
    }

    /// Customers can answer reply emails and their answer reaches the conversation.
    public var emailReplies: Bool { email.receivesReplies }

    private enum CodingKeys: String, CodingKey { case push, email, helpCentre }
    private enum HelpKeys: String, CodingKey { case publishedArticles }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        push = try c.decodeIfPresent(Push.self, forKey: .push) ?? Push(ios: .off, android: .off)
        email = try c.decodeIfPresent(Email.self, forKey: .email) ?? Email(configured: false, receivesReplies: false)
        let help = try? c.nestedContainer(keyedBy: HelpKeys.self, forKey: .helpCentre)
        helpCentreArticles = (try? help?.decodeIfPresent(Int.self, forKey: .publishedArticles)) ?? 0
    }

    public init(push: Push, email: Email, helpCentreArticles: Int) {
        self.push = push; self.email = email; self.helpCentreArticles = helpCentreArticles
    }
}

struct SupportCached<Value: Sendable>: Sendable {
    let value: Value
    let storedAt: Date
    var expiresAt: Date
}

private struct SupportArticleList: Decodable { let articles: [AppReferHelpArticle] }
private struct SupportArticleEnvelope: Decodable { let article: AppReferHelpArticleDetail }

// MARK: - Requests

extension SupportAPI {
    /// Lists and articles are kept in memory for five minutes.
    static let helpCacheSeconds: TimeInterval = 300
    /// Search terms longer than this are cut (the server refuses longer ones).
    static let maxQueryLength = 200

    private func cacheKey(_ parts: String...) -> String { ([currentApiKey ?? ""] + parts).joined(separator: "|") }

    static func normalizedQuery(_ query: String?) -> String? {
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxQueryLength))
    }

    /// Published articles in `language` (the chat's language), best first; with `query`, the
    /// server's search results. A list younger than five minutes is served from memory. When
    /// the request fails, the last list for the same key, language and query is returned
    /// whatever its age; with none, the error is thrown.
    func helpArticleList(query: String?, language: String) async throws -> [AppReferHelpArticle] {
        let q = Self.normalizedQuery(query)
        let key = cacheKey("list", language, q ?? "")
        if let cached = helpLists[key], cached.expiresAt > now() { return cached.value }
        do {
            var items = [("locale", language)]
            if let q { items.append(("q", q)) }
            let (data, _) = try await publicGet("/api/support/v1/articles", query: items, language: language)
            let articles = try JSONDecoder().decode(SupportArticleList.self, from: data).articles
            let at = now()
            if helpLists.count > 40 { helpLists = helpLists.filter { $0.value.expiresAt > at } }
            helpLists[key] = SupportCached(value: articles, storedAt: at, expiresAt: at.addingTimeInterval(Self.helpCacheSeconds))
            return articles
        } catch {
            if let stale = helpLists[key], !(error is CancellationError) { return stale.value }
            throw error
        }
    }

    /// The last article list for `language` (no query), whatever its age.
    func cachedHelpArticleList(language: String) -> [AppReferHelpArticle]? {
        helpLists[cacheKey("list", language, "")]?.value
    }

    /// One article. Throws `AppReferSupportError` with `status` 404 when it doesn't exist or
    /// isn't published. Kept in memory for five minutes; when offline the last copy is used.
    func helpArticle(slug: String, language: String) async throws -> AppReferHelpArticleDetail {
        let key = cacheKey("article", language, slug)
        if let cached = helpArticles[key], cached.expiresAt > now() { return cached.value }
        do {
            let (data, _) = try await publicGet("/api/support/v1/articles/\(slug.urlPathEscaped)", query: [("locale", language)], language: language)
            let article = try JSONDecoder().decode(SupportArticleEnvelope.self, from: data).article
            let at = now()
            if helpArticles.count > 40 { helpArticles = helpArticles.filter { $0.value.expiresAt > at } }
            helpArticles[key] = SupportCached(value: article, storedAt: at, expiresAt: at.addingTimeInterval(Self.helpCacheSeconds))
            return article
        } catch let error as AppReferSupportError where error.status == 404 {
            helpArticles[key] = nil
            throw error
        } catch {
            if let stale = helpArticles[key], !(error is CancellationError) { return stale.value }
            throw error
        }
    }

    /// Support readiness for this app, kept for as long as the server's Cache-Control
    /// `max-age` allows (5 minutes when every configured channel is verified, else 30 s).
    func supportStatus() async throws -> AppReferSupportStatus {
        let key = currentApiKey ?? ""
        if let cached = statusCache[key], cached.expiresAt > now() { return cached.value }
        let (data, response) = try await publicGet("/api/support/v1/status")
        let status = try JSONDecoder().decode(AppReferSupportStatus.self, from: data)
        let at = now()
        let age = Self.maxAge(response.value(forHTTPHeaderField: "Cache-Control")) ?? 30
        statusCache[key] = SupportCached(value: status, storedAt: at, expiresAt: at.addingTimeInterval(age))
        return status
    }

    /// `max-age` from a Cache-Control header, capped at five minutes; nil without one.
    /// `no-store` / `no-cache` mean zero.
    static func maxAge(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        var age: TimeInterval?
        for part in header.lowercased().split(separator: ",") {
            let directive = part.trimmingCharacters(in: .whitespaces)
            if directive == "no-store" || directive == "no-cache" { return 0 }
            if directive.hasPrefix("max-age="), let seconds = Double(directive.dropFirst("max-age=".count)) {
                age = max(0, min(seconds, 300))
            }
        }
        return age
    }

    /// Fills the help caches (tests and previews).
    func seedHelp(language: String, articles: [AppReferHelpArticle], details: [AppReferHelpArticleDetail] = []) {
        let at = now()
        helpLists[cacheKey("list", language, "")] = SupportCached(value: articles, storedAt: at, expiresAt: at.addingTimeInterval(Self.helpCacheSeconds))
        for detail in details {
            helpArticles[cacheKey("article", language, detail.slug)] = SupportCached(value: detail, storedAt: at, expiresAt: at.addingTimeInterval(Self.helpCacheSeconds))
        }
    }
}

extension AppReferSupportError {
    /// The article doesn't exist or isn't published (HTTP 404).
    public var isNotFound: Bool { status == 404 }
}
