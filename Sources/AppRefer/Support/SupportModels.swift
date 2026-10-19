import Foundation

/// A support conversation as the customer sees it.
public struct AppReferSupportConversation: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    public let subject: String
    public let status: String
    public let preview: String
    public let lastMessageAt: String
    /// "customer", "team" or "bot".
    public let lastFrom: String
    /// Team replies the customer hasn't seen yet.
    public let unread: Int

    public var isOpen: Bool { status != "closed" }
}

/// A file on a message. `url` is a signed link, valid for about an hour.
public struct AppReferSupportAttachment: Hashable, Sendable, Decodable {
    public let url: String?
    public let name: String?
    public let contentType: String?
    public let size: Int?

    public var isImage: Bool { contentType?.hasPrefix("image/") ?? false }
}

public struct AppReferSupportMessage: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    /// "customer", "team" or "bot".
    public let from: String
    /// A team member's first name, or the AI assistant's name on "bot" messages.
    public let authorName: String?
    public let text: String
    public let createdAt: String
    public let attachments: [AppReferSupportAttachment]
    /// The AI assistant's note that it passed the conversation to a person.
    public let handoff: Bool?
    /// An offer card sent with this reply: one of the app's offerings, with its state when read.
    public let offer: AppReferSupportOfferCard?

    public var isFromCustomer: Bool { from == "customer" }
    public var isHandoff: Bool { handoff == true }
    public var date: Date? { SupportDates.parse(createdAt) }
}

/// The answer of `AppRefer.support.verifyIdentity(_:)`. `verified` true: Support may use this
/// account's private details (plan, orders, credits) for this session. Otherwise `reason` says
/// why: the server's `malformed`, `bad_signature`, `other_app`, `other_environment`, `expired`,
/// `bad_times`, `already_used`, `user_mismatch`, `session_replaced`, `session_gone` (ask your
/// backend for a new token), or the SDK's `account_changed` (the account changed while it ran)
/// and `identity_cleared` (after `clearIdentity()`).
public struct AppReferSupportIdentityVerification: Equatable, Sendable {
    public let verified: Bool
    public let reason: String?
    public let appUserId: String?

    public init(verified: Bool, reason: String?, appUserId: String?) {
        self.verified = verified
        self.reason = reason
        self.appUserId = appUserId
    }

    static func refused(_ reason: String) -> Self { .init(verified: false, reason: reason, appUserId: nil) }
}

struct SupportIdentityAnswer: Decodable {
    struct Identity: Decodable { let verified: Bool; let reason: String?; let appUserId: String? }
    let identity: Identity
}

/// The app's AI support assistant, set in AppRefer. Every message from it is tagged "AI".
public struct AppReferSupportPersona: Hashable, Sendable, Decodable {
    public let name: String
    public let avatarUrl: String?
    /// Who it passes conversations to ("Jay"); nil means the team.
    public let handoffTo: String?

    var avatar: URL? { avatarUrl.flatMap(URL.init(string:)) }
}

enum SupportDates {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
}

struct SupportConversationList: Decodable { let conversations: [AppReferSupportConversation]; let persona: AppReferSupportPersona? }
struct SupportThread: Decodable { let conversation: AppReferSupportConversation; let messages: [AppReferSupportMessage]; let persona: AppReferSupportPersona? }
struct SupportSent: Decodable { let message: AppReferSupportMessage }
struct SupportSession: Decodable { let session: String }
struct SupportUploadSlot: Decodable { let attachmentId: String; let uploadUrl: String; let headers: [String: String] }

public struct AppReferSupportError: LocalizedError, Sendable {
    public let status: Int
    /// The server's (or the SDK's) English message, for logs. The chat shows its own
    /// localized text instead (`SupportStrings.errorText`).
    public let message: String
    /// What kind of failure, so the chat can explain it in the customer's language.
    enum Reason: Sendable { case server, locked, upload, unavailable }
    var reason: Reason = .server
    public var errorDescription: String? { message }
}
