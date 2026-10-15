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
    public let authorName: String?
    public let text: String
    public let createdAt: String
    public let attachments: [AppReferSupportAttachment]

    public var isFromCustomer: Bool { from == "customer" }
    public var date: Date? { SupportDates.parse(createdAt) }
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

struct SupportConversationList: Decodable { let conversations: [AppReferSupportConversation] }
struct SupportThread: Decodable { let conversation: AppReferSupportConversation; let messages: [AppReferSupportMessage] }
struct SupportSent: Decodable { let message: AppReferSupportMessage }
struct SupportSession: Decodable { let session: String }
struct SupportUploadSlot: Decodable { let attachmentId: String; let uploadUrl: String; let headers: [String: String] }

public struct AppReferSupportError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }
}
