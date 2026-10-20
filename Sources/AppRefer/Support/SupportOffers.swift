import Foundation

// Offer cards in the help chat (server: lib/support/offers.ts). A team member or the app's AI
// assistant attaches one of the app's AppRefer Billing offerings to a reply; the chat draws it as
// a card with the store's own prices and, when tapped, hands it to the app's own paywall through
// `AppRefer.support.onOffer`. The SDK never shows a paywall, never starts a purchase and never
// shows a price, discount or deadline of its own. A purchase is confirmed by Billing as usual.

/// What `AppRefer.support.onOffer` receives when the customer taps an offer card: open your own
/// paywall for `offeringId` (e.g. `AppReferBilling.offerings().all[offer.offeringId]`), with
/// `packageId` preselected when set. Opening it is not a purchase.
public struct AppReferSupportOffer: Hashable, Sendable {
    /// Stable id of the card (`ofc_…`), the same on every device and in your team inbox.
    public let cardId: String
    public let conversationId: String
    /// One of your app's AppRefer Billing offerings.
    public let offeringId: String
    /// The package the team pointed at, or nil for the whole offering.
    public let packageId: String?

    public init(cardId: String, conversationId: String, offeringId: String, packageId: String?) {
        self.cardId = cardId
        self.conversationId = conversationId
        self.offeringId = offeringId
        self.packageId = packageId
    }
}

/// An offer card as the server sends it, with its state now. Prices are never part of it.
public struct AppReferSupportOfferCard: Hashable, Sendable, Decodable {
    public struct Package: Hashable, Sendable, Decodable {
        public let id: String
        /// weekly, monthly, two_month, three_month, six_month, annual, lifetime or custom.
        public let packageType: String
        /// The name the app gave the package in AppRefer, if any.
        public let displayName: String?
        /// The store product on this platform.
        public let productId: String
        /// The customer's current plan or an owned purchase (only checked for verified customers).
        public let current: Bool
    }

    public let cardId: String
    public let offeringId: String
    public let packageId: String?
    /// available, owned or unavailable.
    public let status: String
    /// Why it can't be opened: owned, revoked, expired, offering_unavailable, not_on_platform, account_changed.
    public let reason: String?
    public let packages: [Package]

    public var isAvailable: Bool { status == "available" }
    /// The packages the card points at (one when the team picked a package).
    public var shownPackages: [Package] {
        guard let packageId else { return packages }
        let picked = packages.filter { $0.id == packageId }
        return picked.isEmpty ? packages : picked
    }
}

/// How the chat draws a card: from the server's state and whether the app connected its paywall.
enum SupportOfferLook: Equatable {
    case open
    case owned
    case unavailable
    /// Available, but the app set no `onOffer`: honest text, no button.
    case unsupported

    static func of(_ card: AppReferSupportOfferCard, hasHandler: Bool) -> SupportOfferLook {
        switch card.status {
        case "available": return hasHandler ? .open : .unsupported
        case "owned": return .owned
        default: return .unavailable
        }
    }

    var notice: String? {
        switch self {
        case .open: return nil
        case .owned: return SupportStrings.text("support.offer.owned")
        case .unavailable: return SupportStrings.text("support.offer.unavailable")
        case .unsupported: return SupportStrings.text("support.offer.unsupported")
        }
    }
}

enum SupportOfferText {
    private static let typeKeys = [
        "weekly": "weekly", "monthly": "monthly", "two_month": "twoMonth", "three_month": "threeMonth",
        "six_month": "sixMonth", "annual": "annual", "lifetime": "lifetime",
    ]

    /// The app's own name for the package, else its length in the chat's language, else the
    /// store's product name for a custom package, else "Option".
    static func label(_ p: AppReferSupportOfferCard.Package, storeName: String?) -> String {
        if let name = p.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let key = typeKeys[p.packageType] { return SupportStrings.text("support.offer.package.\(key)") }
        if let storeName, !storeName.isEmpty { return storeName }
        return SupportStrings.text("support.offer.package.custom")
    }

    /// The `support.offer.price.*` key for a store billing period (ISO 8601, e.g. `P1Y`), or nil
    /// for one-time purchases and periods the table doesn't word (the bare store price is shown).
    static func periodKey(_ iso: String?) -> String? {
        guard let iso = iso?.uppercased(), iso.hasPrefix("P"), let unit = iso.last, "DWMY".contains(unit),
              let n = Int(iso.dropFirst().dropLast()), n > 0 else { return nil }
        switch (String(unit), n) {
        case ("D", 7), ("W", 1): return "week"
        case ("D", 28), ("W", 4): return "fourWeeks"
        case ("M", 1): return "month"
        case ("M", 2): return "twoMonths"
        case ("M", 3): return "threeMonths"
        case ("M", 6): return "sixMonths"
        case ("M", 12), ("Y", 1): return "year"
        default: return nil
        }
    }

    /// The store's own regular price with the store's own billing period, e.g. "£29.99/year".
    static func price(_ p: SupportOfferPrice) -> String {
        guard let key = periodKey(p.period) else { return p.price }
        return SupportStrings.text("support.offer.price.\(key)", ["price": p.price])
    }

    /// The tag on a row the customer already has: "Purchased" for a one-off, "Current plan" for a subscription.
    static func ownedTag(_ p: AppReferSupportOfferCard.Package, price: SupportOfferPrice?) -> String? {
        guard p.current else { return nil }
        let oneOff = price.map { $0.oneTime } ?? (p.packageType == "lifetime")
        return SupportStrings.text(oneOff ? "support.offer.purchased" : "support.offer.current")
    }
}

/// Store prices and names for offer cards, by offering then package id. Read from AppRefer
/// Billing's offerings (the store's own formatted regular price and billing period); empty when
/// Billing isn't used here. The price is never an introductory or trial price.
struct SupportOfferPrice: Hashable, Sendable {
    let price: String
    let name: String?
    /// The store's billing period of a subscription (ISO 8601, e.g. `P1M`); nil for one-time purchases.
    var period: String? = nil
    /// A one-time purchase (credit pack, lifetime unlock), not a subscription.
    var oneTime: Bool = false
}

/// Whether the app set `AppRefer.support.onOffer`, readable from the API actor (it rides on the
/// `X-AppRefer-Support-Features` header so the inbox knows whether a card opens a paywall).
final class SupportOfferHandlerFlag: @unchecked Sendable {
    static let shared = SupportOfferHandlerFlag()
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }

    /// `offers` (this SDK draws cards), `offer-handler` (the app opens its paywall from them),
    /// `reviews` (this SDK draws review cards and opens the store page itself) and `testimonials`
    /// (0.13.0: this SDK draws photo/video request cards and runs the capture screen).
    var header: String { isSet ? "offers, offer-handler, reviews, testimonials" : "offers, reviews, testimonials" }
}

/// A receipt the server hasn't confirmed yet. Same id on every retry, so it's stored once.
struct SupportOfferReceipt: Codable, Equatable, Sendable {
    let conversationId: String
    let cardId: String
    /// shown or opened.
    let kind: String
    let clientEventId: String
    let occurredAt: String
    var attempts: Int = 0
}

/// Receipts waiting to be sent, kept on disk so a tap made offline still counts later. Cleared
/// with the Support session (reset, clearIdentity): they belong to that session only.
final class SupportOfferReceipts: @unchecked Sendable {
    static let shared = SupportOfferReceipts()
    static let storageKey = "apprefer_support_offer_receipts"
    static let maxItems = 50
    static let maxAge: TimeInterval = 7 * 86400
    static let maxAttempts = 8
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var pending: [SupportOfferReceipt] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    func enqueue(_ r: SupportOfferReceipt) {
        lock.lock(); defer { lock.unlock() }
        var items = load().filter { $0.clientEventId != r.clientEventId || $0.cardId != r.cardId }
        items.append(r)
        save(items)
    }

    /// Sent (or refused for good): never sent again.
    func remove(_ r: SupportOfferReceipt) {
        lock.lock(); defer { lock.unlock() }
        save(load().filter { !($0.clientEventId == r.clientEventId && $0.cardId == r.cardId) })
    }

    /// A transient failure: kept for later, up to `maxAttempts`.
    func failed(_ r: SupportOfferReceipt) {
        lock.lock(); defer { lock.unlock() }
        save(load().compactMap { item in
            guard item.clientEventId == r.clientEventId, item.cardId == r.cardId else { return item }
            var next = item
            next.attempts += 1
            return next.attempts >= Self.maxAttempts ? nil : next
        })
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func load() -> [SupportOfferReceipt] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let items = try? JSONDecoder().decode([SupportOfferReceipt].self, from: data) else { return [] }
        let oldest = Date().addingTimeInterval(-Self.maxAge)
        return items.filter { (SupportDates.parse($0.occurredAt) ?? .distantPast) > oldest }
    }

    private func save(_ items: [SupportOfferReceipt]) {
        let kept = Array(items.suffix(Self.maxItems))
        if kept.isEmpty { defaults.removeObject(forKey: Self.storageKey); return }
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: Self.storageKey) }
    }
}

struct SupportOfferList: Decodable { let offers: [AppReferSupportOfferCard?] }
struct SupportOfferEventAnswer: Decodable { let offer: AppReferSupportOfferCard? }

enum SupportOfferClock {
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// The outcome of asking the server to record an `opened` receipt before the paywall opens.
enum SupportOfferOpenCheck: Equatable {
    /// Recorded (or a duplicate): open the paywall.
    case recorded(AppReferSupportOfferCard?)
    /// The server says the card can't be opened now (withdrawn, changed…): redraw, don't open.
    case refused
    /// No answer in time: open anyway (the store and the paywall are the real gate); the
    /// receipt stays queued and is sent later.
    case offline
}

extension SupportAPI {
    /// Every offer card in a conversation with its state now (after a purchase, restore,
    /// sign-in, catalogue change or reopening the chat), without reloading the messages.
    func offerCards(_ conversationId: String) async throws -> [AppReferSupportOfferCard] {
        let data = try await sessionCall("GET", "/api/support/v1/conversations/\(conversationId.urlPathEscaped)/offers?platform=ios")
        return try JSONDecoder().decode(SupportOfferList.self, from: data).offers.compactMap { $0 }
    }

    /// Sends one receipt. Throws on network or server failure; a 4xx other than 408/429 is final.
    /// Review cards (`rvc_…`) share this queue and post to their own route.
    func sendOfferReceipt(_ r: SupportOfferReceipt) async throws -> AppReferSupportOfferCard? {
        let body: [String: Any] = ["kind": r.kind, "clientEventId": r.clientEventId, "occurredAt": r.occurredAt]
        let kind = r.cardId.hasPrefix("rvc_") ? "reviews" : "offers"
        let path = "/api/support/v1/conversations/\(r.conversationId.urlPathEscaped)/\(kind)/\(r.cardId.urlPathEscaped)/events?platform=ios"
        let data = try await sessionCall("POST", path, body: body)
        return (try? JSONDecoder().decode(SupportOfferEventAnswer.self, from: data))?.offer
    }

    /// Sends every queued receipt once; keeps the ones that failed for a transient reason.
    func flushOfferReceipts(_ queue: SupportOfferReceipts = .shared) async {
        for r in queue.pending {
            do {
                _ = try await sendOfferReceipt(r)
                queue.remove(r)
            } catch let e as AppReferSupportError where e.status >= 400 && e.status < 500 && e.status != 408 && e.status != 429 {
                queue.remove(r)
            } catch is CancellationError {
                return
            } catch {
                queue.failed(r)
            }
        }
    }
}

extension String {
    /// A receipt id from the card and a random part (`[A-Za-z0-9_-]{8,64}`).
    static func supportOfferEventId(_ prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
    }
}

#if os(iOS)
import SwiftUI
import StoreKit

/// Store prices for the offerings on screen, from AppRefer Billing (the store's own formatted
/// price and product name). Empty when the app doesn't use AppRefer Billing: cards then list the
/// packages without prices, never with made-up ones.
enum SupportOfferPrices {
    static func load(_ offeringIds: Set<String>) async -> [String: [String: SupportOfferPrice]] {
        guard !offeringIds.isEmpty, AppReferBilling.isConfigured, let all = try? await AppReferBilling.offerings().all else { return [:] }
        var out: [String: [String: SupportOfferPrice]] = [:]
        for id in offeringIds {
            guard let offering = all[id] else { continue }
            var byPackage: [String: SupportOfferPrice] = [:]
            for p in offering.availablePackages { byPackage[p.identifier] = price(of: p.storeProduct) }
            out[id] = byPackage
        }
        return out
    }

    /// StoreKit's `displayPrice` is the regular price (introductory offers are separate), shown
    /// with the subscription's own period.
    static func price(of product: Product) -> SupportOfferPrice {
        let period = product.subscription.map { iso($0.subscriptionPeriod) }
        return SupportOfferPrice(price: product.displayPrice, name: product.displayName, period: period, oneTime: product.subscription == nil)
    }

    static func iso(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = "D"
        case .week: unit = "W"
        case .month: unit = "M"
        case .year: unit = "Y"
        @unknown default: unit = "?"
        }
        return "P\(period.value)\(unit)"
    }
}

/// The card under a team or AI message: heading, the packages with store prices (and "Current
/// plan"), and one button that hands the offer to the app's paywall. Disabled cards say why.
struct SupportOfferCardView: View {
    let card: AppReferSupportOfferCard
    let prices: [String: SupportOfferPrice]
    let palette: SupportPalette
    let hasHandler: Bool
    let opening: Bool
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var look: SupportOfferLook { .of(card, hasHandler: hasHandler) }
    private var active: Bool { look == .open }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(active ? palette.accent : SupportColors.muted)
                    .frame(width: 26, height: 26)
                    .background((active ? palette.accent : SupportColors.muted).opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                Text(SupportStrings.text("support.offer.title")).font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            let rows = card.status == "unavailable" ? [] : card.shownPackages
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider().opacity(0.5) }
                        row(p)
                    }
                }
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let notice = look.notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: look == .owned ? "checkmark.circle.fill" : "info.circle").font(.system(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(notice).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(SupportColors.muted)
            } else {
                Button(action: open) {
                    HStack(spacing: 8) {
                        if opening { ProgressView().tint(palette.onAccent) }
                        Text(SupportStrings.text("support.offer.open")).font(.system(size: 15.5, weight: .semibold))
                    }
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(palette.bubble, in: Capsule())
                }
                .buttonStyle(SupportPressStyle())
                .disabled(opening)
                .accessibilityHint(SupportStrings.text("support.offer.a11y.hint"))
            }
        }
        .padding(14)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(active ? palette.accent.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 3)
        .opacity(look == .unavailable ? 0.85 : 1)
    }

    private func row(_ p: AppReferSupportOfferCard.Package) -> some View {
        let price = prices[p.id]
        let label = SupportOfferText.label(p, storeName: price?.name)
        return HStack(spacing: 8) {
            Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let tag = SupportOfferText.ownedTag(p, price: price) {
                Text(tag).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(palette.accent.opacity(0.12), in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 8)
            // The store's price and period are never truncated: the package name wraps instead.
            if let price { Text(SupportOfferText.price(price)).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.primary).fixedSize() }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
#endif

/// Opening a card: record the `opened` receipt (asking the server whether the card can still be
/// opened, for up to `timeout`), then hand it to the app. A refusal redraws the card instead.
struct SupportOfferOpener: Sendable {
    var queue: SupportOfferReceipts = .shared
    var timeout: UInt64 = 3_000_000_000
    var send: @Sendable (SupportOfferReceipt) async throws -> AppReferSupportOfferCard? = { try await SupportAPI.shared.sendOfferReceipt($0) }
    var now: @Sendable () -> Date = { Date() }

    func receipt(for card: AppReferSupportOfferCard, conversationId: String) -> SupportOfferReceipt {
        receipt(cardId: card.cardId, conversationId: conversationId)
    }

    func receipt(cardId: String, conversationId: String) -> SupportOfferReceipt {
        SupportOfferReceipt(conversationId: conversationId, cardId: cardId, kind: "opened",
                            clientEventId: .supportOfferEventId("open"), occurredAt: SupportOfferClock.iso(now()))
    }

    func check(_ r: SupportOfferReceipt) async -> SupportOfferOpenCheck {
        queue.enqueue(r)
        let send = self.send
        let outcome: SupportOfferOpenCheck = await withTaskGroup(of: SupportOfferOpenCheck?.self) { group in
            group.addTask {
                do { return .recorded(try await send(r)) }
                catch let e as AppReferSupportError where e.status == 404 || e.status == 409 { return .refused }
                catch { return .offline }
            }
            group.addTask { [timeout] in
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .offline
        }
        // Offline: the receipt stays queued and goes out later with the same id.
        if outcome != .offline { queue.remove(r) }
        return outcome
    }
}

/// The receipt id a card's `shown` receipt always uses, so it is stored once per card.
func supportOfferShownId(_ cardId: String) -> String { "shown_" + cardId.replacingOccurrences(of: "ofc_", with: "") }
