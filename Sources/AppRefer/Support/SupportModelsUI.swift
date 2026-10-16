#if os(iOS)
import SwiftUI
import UIKit
import ImageIO

@MainActor
final class SupportAccountState: ObservableObject {
    static let shared = SupportAccountState()
    @Published var generation = 0
}

/// Screens on top of the help home.
enum SupportRoute: Hashable {
    case thread(id: String, subject: String)
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

    func refresh() async {
        name = await SupportAPI.shared.displayName
        do {
            conversations = try await SupportAPI.shared.conversations()
                .sorted { ($0.isOpen ? 0 : 1, $1.lastMessageAt) < ($1.isOpen ? 0 : 1, $0.lastMessageAt) }
            await SupportPersonaStore.shared.refresh()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
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
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// New messages since the last poll. Runs only while the chat is open and active.
    func poll() async {
        guard loaded, let t = try? await SupportAPI.shared.thread(id, after: lastSeen) else { return }
        // A persona switched on, changed or off shows while the chat is open.
        await SupportPersonaStore.shared.refresh()
        merge(t.messages)
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

    func send(text: String, images: [UIImage]) async {
        await deliver(PendingMessage(text: text, images: images))
    }

    private func deliver(_ p: PendingMessage) async {
        pending.append(p)
        do {
            var ids: [String] = []
            for image in images(p) { ids.append(try await SupportAPI.shared.upload(await SupportImages.jpegOffMain(image))) }
            let sent = try await SupportAPI.shared.send(id, text: p.text, attachmentIds: ids, clientMessageId: p.id)
            pending.removeAll { $0.id == p.id }
            merge([sent])
        } catch {
            if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = true }
            self.error = error.localizedDescription
        }
    }

    /// Same clientMessageId, fresh uploads: a retry after a lost response returns the stored message.
    func retry(_ p: PendingMessage) async {
        pending.removeAll { $0.id == p.id }
        var again = p
        again.failed = false
        await deliver(again)
    }

    private func images(_ p: PendingMessage) -> [UIImage] { p.images }
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
