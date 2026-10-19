#if os(iOS)
import SwiftUI
import UIKit
import ImageIO

@MainActor
final class SupportAccountState: ObservableObject {
    static let shared = SupportAccountState()
    @Published var generation = 0
    private var actions: [UUID: Task<Void, Never>] = [:]
    func run(_ action: @escaping @MainActor (Int) async -> Void) {
        let epoch = SupportAPI.shared.actionGeneration
        let id = UUID()
        actions[id] = Task {
            guard !Task.isCancelled else { return }
            await action(epoch)
            actions[id] = nil
        }
    }
    func reset() {
        actions.values.forEach { $0.cancel() }
        actions.removeAll()
        generation += 1
    }
}

/// Screens on top of the help home.
enum SupportRoute: Hashable {
    case thread(id: String, subject: String)
    /// Every help article, with search (`search` focuses the field on arrival).
    case help(search: Bool)
    case article(slug: String, title: String)
}

/// "Message us" from the help centre: back to the home's message bar, optionally on an
/// article (its title becomes the subject).
struct SupportComposeRequest: Equatable {
    let id = UUID()
    let subject: String?
}

/// The app's AI assistant as last seen from AppRefer, shared by the help screens.
@MainActor
final class SupportPersonaStore: ObservableObject {
    static let shared = SupportPersonaStore()
    @Published private(set) var persona: AppReferSupportPersona?

    func clear() { persona = nil }

    func refresh() async {
        let latest = await SupportAPI.shared.persona
        if latest != persona { persona = latest }
    }
}

@MainActor
final class SupportHomeModel: ObservableObject {
    @Published var conversations: [AppReferSupportConversation] = []
    @Published var loaded = false
    @Published var error: String?
    @Published var name: String?
    /// Published help articles in the chat's language; empty hides the help section.
    @Published var articles: [AppReferHelpArticle] = []
    /// Set by "Message us" in the help centre.
    @Published var compose: SupportComposeRequest?

    func refresh() async {
        async let help: Void = refreshArticles()
        name = await SupportAPI.shared.displayName
        do {
            conversations = try await SupportAPI.shared.conversations()
                .sorted { ($0.isOpen ? 0 : 1, $1.lastMessageAt) < ($1.isOpen ? 0 : 1, $0.lastMessageAt) }
            await SupportPersonaStore.shared.refresh()
            error = nil
        } catch {
            self.error = SupportStrings.errorText(error)
        }
        await help
        loaded = true
    }

    /// The article list (memory cache first, five minutes). Offline keeps what was shown,
    /// or the last list; never an error.
    func refreshArticles() async {
        let language = SupportStrings.language
        if articles.isEmpty, let cached = await SupportAPI.shared.cachedHelpArticleList(language: language) { articles = cached }
        if let fresh = try? await SupportAPI.shared.helpArticleList(query: nil, language: language) { articles = fresh }
    }

    /// The open conversation to pick up again: unread first, then the newest.
    var current: AppReferSupportConversation? {
        conversations.filter(\.isOpen).max { ($0.unread > 0 ? 1 : 0, $0.lastMessageAt) < ($1.unread > 0 ? 1 : 0, $1.lastMessageAt) }
    }

    var others: [AppReferSupportConversation] {
        let currentId = current?.id
        return conversations.filter { $0.id != currentId }
    }
}

/// A message being sent, shown at once and replaced by the stored one.
struct PendingMessage: Identifiable, Hashable {
    /// Also the clientMessageId: the same on every retry, so the server never stores it twice.
    var id = UUID().uuidString
    let text: String
    let images: [UIImage]
    var failed = false
}

@MainActor
final class SupportThreadModel: ObservableObject {
    let id: String
    @Published var messages: [AppReferSupportMessage] = []
    @Published var pending: [PendingMessage] = []
    @Published var loaded = false
    @Published var error: String?
    private var lastSeen: String?

    init(id: String) { self.id = id }

    func load() async {
        do {
            let t = try await SupportAPI.shared.thread(id, after: nil)
            await SupportPersonaStore.shared.refresh()
            messages = t.messages
            lastSeen = t.messages.last?.createdAt
            error = nil
            absorbOffers(t.messages)
        } catch {
            self.error = SupportStrings.errorText(error)
        }
        loaded = true
        await SupportAPI.shared.flushOfferReceipts()
    }

    // MARK: Offer cards

    /// Each card's latest state by card id (a message keeps the state it was first read with).
    @Published var offers: [String: AppReferSupportOfferCard] = [:]
    /// Store prices by offering, then package.
    @Published var prices: [String: [String: SupportOfferPrice]] = [:]
    /// The card being opened (its button shows progress).
    @Published var opening: String?
    private var shownSent: Set<String> = []
    private var lastOfferRefresh = Date.distantPast
    var opener = SupportOfferOpener()

    func card(_ m: AppReferSupportMessage) -> AppReferSupportOfferCard? {
        guard let offer = m.offer else { return nil }
        return offers[offer.cardId] ?? offer
    }

    private func absorbOffers(_ incoming: [AppReferSupportMessage]) {
        let cards = incoming.compactMap(\.offer)
        guard !cards.isEmpty else { return }
        for c in cards { offers[c.cardId] = c }
        Task { await loadPrices() }
    }

    func loadPrices() async {
        let ids = Set(offers.values.map(\.offeringId))
        let loaded = await SupportOfferPrices.load(ids)
        if loaded != prices { prices = loaded }
    }

    /// Fresh states for every card here, after a purchase, restore, sign-in, catalogue change
    /// or coming back to the app; also re-reads store prices.
    func refreshOffers() async {
        guard !offers.isEmpty, let cards = try? await SupportAPI.shared.offerCards(id) else { return }
        lastOfferRefresh = Date()
        for c in cards { offers[c.cardId] = c }
        await loadPrices()
    }

    /// While the chat is open, card states are re-read every 30 seconds.
    func refreshOffersIfDue() async {
        guard !offers.isEmpty, Date().timeIntervalSince(lastOfferRefresh) > 30 else { return }
        await refreshOffers()
    }

    /// Once per card per launch (and stored once per card on the server).
    func cardShown(_ card: AppReferSupportOfferCard) {
        guard !shownSent.contains(card.cardId) else { return }
        shownSent.insert(card.cardId)
        opener.queue.enqueue(SupportOfferReceipt(conversationId: id, cardId: card.cardId, kind: "shown",
                                                 clientEventId: supportOfferShownId(card.cardId), occurredAt: SupportOfferClock.iso(Date())))
        Task { await SupportAPI.shared.flushOfferReceipts(opener.queue) }
    }

    /// The customer tapped "View offer": checked with the server, then handed to the app's paywall.
    func open(_ card: AppReferSupportOfferCard, generation epoch: Int) async {
        guard opening == nil, card.isAvailable, SupportOfferHandlerFlag.shared.isSet else { return }
        opening = card.cardId
        defer { opening = nil }
        let outcome = await opener.check(opener.receipt(for: card, conversationId: id))
        guard epoch == SupportAPI.shared.actionGeneration, !Task.isCancelled else { return }
        switch outcome {
        case .refused:
            await refreshOffers()
            return
        case .recorded(let fresh):
            if let fresh { offers[fresh.cardId] = fresh }
        case .offline:
            break
        }
        AppReferSupport.shared.deliver(AppReferSupportOffer(cardId: card.cardId, conversationId: id, offeringId: card.offeringId, packageId: card.packageId))
    }

    /// New messages since the last poll. Runs only while the chat is open and active.
    func poll() async {
        guard loaded, let t = try? await SupportAPI.shared.thread(id, after: lastSeen) else { return }
        // A persona switched on, changed or off shows while the chat is open.
        await SupportPersonaStore.shared.refresh()
        merge(t.messages)
        absorbOffers(t.messages)
        // Only polls move the cursor: a team reply that landed just before our own
        // send is then still fetched.
        if let newest = t.messages.last?.createdAt { lastSeen = newest }
    }

    private func merge(_ incoming: [AppReferSupportMessage]) {
        let known = Set(messages.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        messages.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func send(text: String, images: [UIImage], generation epoch: Int) async {
        await deliver(PendingMessage(text: text, images: images), generation: epoch)
    }

    private func deliver(_ p: PendingMessage, generation epoch: Int) async {
        guard epoch == SupportAPI.shared.actionGeneration, !Task.isCancelled else { return }
        pending.append(p)
        do {
            var ids: [String] = []
            for image in images(p) { ids.append(try await SupportAPI.shared.upload(await SupportImages.jpegOffMain(image), generation: epoch)) }
            let sent = try await SupportAPI.shared.send(id, text: p.text, attachmentIds: ids, clientMessageId: p.id, generation: epoch)
            pending.removeAll { $0.id == p.id }
            merge([sent])
            await refreshOffersIfDue()
        } catch {
            if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = true }
            self.error = SupportStrings.errorText(error)
        }
    }

    /// Same clientMessageId, fresh uploads: a retry after a lost response returns the stored message.
    func retry(_ p: PendingMessage, generation epoch: Int) async {
        pending.removeAll { $0.id == p.id }
        var again = p
        again.failed = false
        await deliver(again, generation: epoch)
    }

    private func images(_ p: PendingMessage) -> [UIImage] { p.images }
}

/// The help centre screen: every article grouped by category, and search.
@MainActor
final class SupportHelpModel: ObservableObject {
    @Published var all: [AppReferHelpArticle] = []
    @Published var loaded = false
    @Published var failed = false
    @Published var query = ""
    /// nil while the field is empty.
    @Published var results: [AppReferHelpArticle]?
    @Published var searching = false
    private var searchTask: Task<Void, Never>?
    /// The server search waits this long after the last keystroke.
    var debounceNanoseconds: UInt64 = 300_000_000

    func load() async {
        let language = SupportStrings.language
        if all.isEmpty, let cached = await SupportAPI.shared.cachedHelpArticleList(language: language) { all = cached }
        do {
            all = try await SupportAPI.shared.helpArticleList(query: nil, language: language)
            failed = false
        } catch {
            failed = all.isEmpty
        }
        loaded = true
    }

    /// Filters what's on screen at once, then asks the server (which also searches bodies).
    func search(_ text: String) {
        searchTask?.cancel()
        guard let q = SupportAPI.normalizedQuery(text) else {
            results = nil
            searching = false
            return
        }
        results = Self.localMatches(all, q)
        searching = true
        let language = SupportStrings.language
        let delay = debounceNanoseconds
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            let found = try? await SupportAPI.shared.helpArticleList(query: q, language: language)
            guard !Task.isCancelled, let self else { return }
            if let found { self.results = found }
            self.searching = false
        }
    }

    /// Articles whose title, summary or category contain every word of `query`.
    static func localMatches(_ articles: [AppReferHelpArticle], _ query: String) -> [AppReferHelpArticle] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return articles.filter { a in
            let haystack = [a.title, a.summary, a.category ?? ""].joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Articles by category in the server's order; uncategorised ones last ("More articles"),
    /// or with no heading at all when nothing has a category.
    static func groups(_ articles: [AppReferHelpArticle]) -> [(title: String?, articles: [AppReferHelpArticle])] {
        var order: [String] = []
        var byCategory: [String: [AppReferHelpArticle]] = [:]
        var loose: [AppReferHelpArticle] = []
        for article in articles {
            guard let category = article.category?.trimmingCharacters(in: .whitespaces), !category.isEmpty else { loose.append(article); continue }
            if byCategory[category] == nil { order.append(category) }
            byCategory[category, default: []].append(article)
        }
        var result: [(title: String?, articles: [AppReferHelpArticle])] = order.map { ($0, byCategory[$0]!) }
        if !loose.isEmpty { result.append((order.isEmpty ? nil : SupportStrings.text("support.help.otherCategory"), loose)) }
        return result
    }
}

/// One article in the reader.
@MainActor
final class SupportArticleModel: ObservableObject {
    let slug: String
    @Published var detail: AppReferHelpArticleDetail?
    @Published var blocks: [SupportMarkdownBlock] = []
    @Published var failed = false

    init(slug: String) { self.slug = slug }

    func load() async {
        failed = false
        do {
            let article = try await SupportAPI.shared.helpArticle(slug: slug, language: SupportStrings.language)
            blocks = SupportMarkdown.blocks(article.body)
            detail = article
        } catch is CancellationError {
        } catch {
            failed = detail == nil
        }
    }
}

/// What the line under the customer's last message promises about the reply.
enum SupportReplyNotice: Equatable {
    /// "we'll notify you" (also when the status is unknown, as before 0.10.0).
    case push
    case email
    /// Neither push nor email can reach them: the reply shows in the chat.
    case inApp

    static func choose(status: AppReferSupportStatus?, hasPushToken: Bool, hasEmail: Bool) -> SupportReplyNotice {
        guard let status else { return .push }
        if status.pushReady && hasPushToken { return .push }
        if status.email.configured && hasEmail { return .email }
        return .inApp
    }

    static func current() async -> SupportReplyNotice {
        let status = try? await SupportAPI.shared.supportStatus()
        let email = await SupportAPI.shared.customerEmail
        return choose(status: status, hasPushToken: SupportAPI.shared.hasPushToken, hasEmail: email != nil)
    }

    func text(_ date: Date?) -> String {
        let time = date.map { SupportText.clock($0) }
        switch self {
        case .push:
            return time.map { SupportStrings.text("support.thread.sentNotice", ["time": $0]) } ?? SupportStrings.text("support.thread.sentNoticeNoTime")
        case .email:
            return time.map { SupportStrings.text("support.status.sentNoticeEmail", ["time": $0]) } ?? SupportStrings.text("support.status.sentNoticeEmailNoTime")
        case .inApp:
            return time.map { SupportStrings.text("support.status.sentNoticeInApp", ["time": $0]) } ?? SupportStrings.text("support.status.sentNoticeInAppNoTime")
        }
    }
}

enum SupportImages {
    /// Compression off the main thread, so the chat stays responsive.
    static func jpegOffMain(_ image: UIImage) async -> Data {
        await Task.detached(priority: .userInitiated) { jpeg(image) }.value
    }

    /// Decodes a picked file straight to at most 1600 px (never the full-size bitmap).
    static func downsampled(_ url: URL, maxSide: CGFloat = 1600) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    /// Screenshots shrink to at most 1600 px and about 700 KB before upload.
    static func jpeg(_ image: UIImage) -> Data {
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        var quality: CGFloat = 0.75
        var data = resized.jpegData(compressionQuality: quality) ?? Data()
        while data.count > 700_000 && quality > 0.3 {
            quality -= 0.15
            data = resized.jpegData(compressionQuality: quality) ?? data
        }
        return data
    }
}
#endif
