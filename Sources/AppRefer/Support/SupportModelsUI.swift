#if os(iOS)
import SwiftUI
import UIKit

/// Screens inside the help chat.
enum SupportRoute: Hashable {
    case compose
    case thread(id: String, subject: String)
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
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// A message being sent, shown at once and replaced by the stored one.
struct PendingMessage: Identifiable, Hashable {
    let id = UUID().uuidString
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
            messages = t.messages
            lastSeen = t.messages.last?.createdAt
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// New messages since the last one we have. Runs only while the chat is open.
    func poll() async {
        guard loaded, let t = try? await SupportAPI.shared.thread(id, after: lastSeen) else { return }
        merge(t.messages)
    }

    private func merge(_ incoming: [AppReferSupportMessage]) {
        let known = Set(messages.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        lastSeen = messages.last?.createdAt ?? lastSeen
    }

    func send(text: String, images: [UIImage]) async {
        let p = PendingMessage(text: text, images: images)
        pending.append(p)
        do {
            var ids: [String] = []
            for image in images { ids.append(try await SupportAPI.shared.upload(SupportImages.jpeg(image))) }
            let sent = try await SupportAPI.shared.send(id, text: text, attachmentIds: ids)
            pending.removeAll { $0.id == p.id }
            merge([sent])
        } catch {
            if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = true }
            self.error = error.localizedDescription
        }
    }

    func retry(_ p: PendingMessage) async {
        pending.removeAll { $0.id == p.id }
        await send(text: p.text, images: p.images)
    }
}

enum SupportImages {
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
