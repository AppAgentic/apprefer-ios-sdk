import Foundation

// Review cards in the help chat (server: lib/support/reviews.ts). A team member can attach an
// optional "Write a review" card to a reply; tapping it opens the app's own App Store page with
// the write-review action (`https://apps.apple.com/app/id<id>?action=write-review`), as Apple
// recommends for a review button. The SDK never calls the quota-limited `requestReview` from a
// button, never shows stars, never asks whether the customer likes the app, and never says a
// review was written: opening the page is all it knows.

/// A review card as the server sends it, with its state now.
public struct AppReferSupportReviewCard: Hashable, Sendable, Decodable {
    /// Stable id of the card (`rvc_…`).
    public let cardId: String
    /// available or unavailable.
    public let status: String
    /// Why it can't be opened: revoked, expired, account_changed, disabled, store_changed, not_on_platform.
    public let reason: String?
    /// app_store or play_store (nil when unavailable).
    public let store: String?
    /// The store page to open; nil unless available.
    public let url: String?

    public var isAvailable: Bool { status == "available" }
}

enum SupportReviewLook: Equatable {
    case open(URL)
    case unavailable
    /// No store page for this device (or a link the SDK won't open).
    case unsupported

    static func of(_ card: AppReferSupportReviewCard) -> SupportReviewLook {
        guard card.isAvailable else { return card.reason == "not_on_platform" ? .unsupported : .unavailable }
        guard let url = SupportReviewLink.validated(card.url) else { return .unsupported }
        return .open(url)
    }
}

enum SupportReviewLink {
    /// Only the App Store's own write-review page for one app id: https, apps.apple.com, `/app/id<digits>`,
    /// `action=write-review`, nothing else. Anything else is never opened, whatever the server says.
    static func validated(_ raw: String?) -> URL? {
        guard let raw, let c = URLComponents(string: raw), c.scheme == "https", c.host?.lowercased() == "apps.apple.com",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              c.path.range(of: #"^/app/id[1-9][0-9]{4,11}$"#, options: .regularExpression) != nil,
              c.queryItems == [URLQueryItem(name: "action", value: "write-review")],
              let url = c.url else { return nil }
        return url
    }

    /// The string-table suffix for a store (`appStore` / `googlePlay`): each language words the store its own way.
    static func storeKey(_ store: String?) -> String { store == "play_store" ? "googlePlay" : "appStore" }
}

struct SupportReviewList: Decodable { let reviews: [AppReferSupportReviewCard?] }

extension SupportAPI {
    /// Every review card in a conversation with its state now.
    func reviewCards(_ conversationId: String) async throws -> [AppReferSupportReviewCard] {
        let data = try await sessionCall("GET", "/api/support/v1/conversations/\(conversationId.urlPathEscaped)/reviews?platform=ios")
        return try JSONDecoder().decode(SupportReviewList.self, from: data).reviews.compactMap { $0 }
    }
}

/// The receipt id a review card's `shown` receipt always uses (once per card).
func supportReviewShownId(_ cardId: String) -> String { "shown_" + cardId.replacingOccurrences(of: "rvc_", with: "r") }

#if os(iOS)
import SwiftUI
import UIKit

/// The card under a team message: heading, one neutral line naming the store, and "Write a review".
struct SupportReviewCardView: View {
    let card: AppReferSupportReviewCard
    let palette: SupportPalette
    let opening: Bool
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var look: SupportReviewLook { .of(card) }
    private var active: Bool { if case .open = look { return true }; return false }
    private var store: String { SupportReviewLink.storeKey(card.store ?? "app_store") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(active ? palette.accent : SupportColors.muted)
                    .frame(width: 26, height: 26)
                    .background((active ? palette.accent : SupportColors.muted).opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                Text(SupportStrings.text("support.review.title")).font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            switch look {
            case .open:
                Text(SupportStrings.text("support.review.body.\(store)")).font(.system(size: 14.5))
                    .foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                Button(action: open) {
                    HStack(spacing: 8) {
                        if opening { ProgressView().tint(palette.onAccent) }
                        Text(SupportStrings.text("support.review.open")).font(.system(size: 15.5, weight: .semibold))
                    }
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(palette.bubble, in: Capsule())
                }
                .buttonStyle(SupportPressStyle())
                .disabled(opening)
                .accessibilityHint(SupportStrings.text("support.review.a11y.hint.\(store)"))
            case .unavailable, .unsupported:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                    Text(SupportStrings.text(look == .unavailable ? "support.review.unavailable" : "support.review.unsupported"))
                        .font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(SupportColors.muted)
            }
        }
        .padding(14)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(active ? palette.accent.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 3)
        .opacity(active ? 1 : 0.85)
    }
}

/// Opens a validated store page with the system URL opener (the App Store app). No extra dependency.
@MainActor
enum SupportReviewOpener {
    static var openURL: (URL) -> Void = { UIApplication.shared.open($0) }
}
#endif
