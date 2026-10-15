#if os(iOS)
import SwiftUI
import PhotosUI

/// The whole help chat: home, new message and conversations. Use
/// `AppRefer.support.open()` to present it, or embed this view yourself.
public struct AppReferSupportView: View {
    @StateObject private var home = SupportHomeModel()
    @State private var path: [SupportRoute] = []
    @Environment(\.dismiss) private var dismiss
    private let initialConversation: String?
    private let initialDraft: String?

    public init(conversationId: String? = nil) {
        self.initialConversation = conversationId
        self.initialDraft = nil
    }

    /// Opens on a new message, optionally pre-filled.
    public init(composing draft: String) {
        self.initialConversation = nil
        self.initialDraft = draft
    }

    private var accent: Color { AppReferSupport.shared.accentColor ?? .accentColor }

    public var body: some View {
        ZStack {
            SupportHomeScreen(model: home, accent: accent, close: { dismiss() }, push: push)
            ForEach(Array(path.enumerated()), id: \.element) { index, route in
                Group {
                    switch route {
                    case .compose:
                        SupportComposeScreen(accent: accent, draft: initialDraft ?? "", back: pop) { id, subject in
                            path.removeLast()
                            push(.thread(id: id, subject: subject))
                        }
                    case let .thread(id, subject):
                        SupportThreadScreen(id: id, subject: subject, accent: accent, back: pop)
                    }
                }
                .background(Color(.systemBackground).ignoresSafeArea())
                .transition(.move(edge: .trailing))
                .zIndex(Double(index + 1))
            }
        }
        .tint(accent)
        .task {
            if let initialConversation, path.isEmpty { path = [.thread(id: initialConversation, subject: "")] }
            if initialDraft != nil, path.isEmpty { path = [.compose] }
        }
    }

    private func push(_ route: SupportRoute) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { path.append(route) }
    }

    private func pop() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { _ = path.popLast() }
        Task { await home.refresh() }
    }
}

// MARK: - Top bar

struct SupportTopBar<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var leadingSymbol: String
    let leading: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Button(action: leading) {
                Image(systemName: leadingSymbol).font(.body.weight(.semibold)).frame(width: 40, height: 40)
            }
            .foregroundStyle(.primary)
            .supportGlass()
            .accessibilityLabel(leadingSymbol == "xmark" ? "Close" : "Back")
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .supportGlass()
            Spacer(minLength: 0)
            trailing().frame(minWidth: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Home

struct SupportHomeScreen: View {
    @ObservedObject var model: SupportHomeModel
    let accent: Color
    let close: () -> Void
    let push: (SupportRoute) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !model.conversations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.conversations.count == 1 ? "Your conversation" : "Your conversations")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
                            VStack(spacing: 0) {
                                ForEach(model.conversations) { c in
                                    Button { push(.thread(id: c.id, subject: c.subject)) } label: { row(c) }
                                        .buttonStyle(.plain)
                                    if c.id != model.conversations.last?.id { Divider().padding(.leading, 64) }
                                }
                            }
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    } else if !model.loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    if let error = model.error, model.conversations.isEmpty {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 72)
                .padding(.bottom, 120)
            }
            SupportTopBar(title: "Help", leadingSymbol: "xmark", leading: close) { EmptyView() }
        }
        .overlay(alignment: .bottom) {
            Button { push(.compose) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Send us a message").font(.headline)
                        Text("Screenshots welcome").font(.caption).opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .task { await model.refresh() }
        .task {
            // Keep the list fresh while the help screen is open; nothing runs once it closes.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await model.refresh()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppReferSupport.shared.resolvedTitle).font(.subheadline.weight(.semibold)).foregroundStyle(accent)
            Text(model.name.map { "Hi \($0.split(separator: " ").first.map(String.init) ?? $0) 👋" } ?? "Hi there 👋")
                .font(.largeTitle.weight(.bold))
            Text(AppReferSupport.shared.replyTimeText).font(.body).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func row(_ c: AppReferSupportConversation) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.15))
                Image(systemName: c.isOpen ? "bubble.left.fill" : "checkmark").font(.footnote.weight(.bold)).foregroundStyle(accent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.subject).font(.body.weight(c.unread > 0 ? .semibold : .regular)).lineLimit(1)
                Text(c.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if c.unread > 0 {
                Text("\(c.unread)").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(accent, in: Capsule())
                    .accessibilityLabel("\(c.unread) unread")
            } else {
                Text(SupportText.time(SupportDates.parse(c.lastMessageAt))).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - New message

struct SupportComposeScreen: View {
    let accent: Color
    let back: () -> Void
    let started: (String, String) -> Void
    @State private var text: String

    init(accent: Color, draft: String = "", back: @escaping () -> Void, started: @escaping (String, String) -> Void) {
        self.accent = accent
        self.back = back
        self.started = started
        _text = State(initialValue: draft)
    }
    @State private var images: [UIImage] = []
    @State private var picking = false
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var canSend: Bool { !sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("How can we help? Tell us what happened.").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                        }
                        TextEditor(text: $text).focused($focused).frame(minHeight: 160)
                            .supportHideEditorBackground()
                    }
                    SupportAttachmentStrip(images: $images, accent: accent) { picking = true }
                    Text(contextLine).font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 72)
            }
            SupportTopBar(title: "New message", subtitle: AppReferSupport.shared.resolvedTitle, leadingSymbol: "chevron.left", leading: back) {
                Button { Task { await send() } } label: {
                    Group {
                        if sending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.body.weight(.bold)) }
                    }
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.white)
                    .background(canSend ? accent : Color.gray.opacity(0.4), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .sheet(isPresented: $picking) { SupportPhotoPicker(limit: max(1, 4 - images.count)) { images.append(contentsOf: $0) } }
        .onAppear { focused = true }
    }

    private var contextLine: String {
        let c = SupportAPI.context()
        let parts = ["app \(c["appVersion"] as? String ?? "?")", c["device"] as? String, c["os"] as? String].compactMap { $0 }
        return "Sent with: " + parts.joined(separator: " · ")
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            var ids: [String] = []
            for image in images { ids.append(try await SupportAPI.shared.upload(SupportImages.jpeg(image))) }
            let t = try await SupportAPI.shared.start(text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachmentIds: ids)
            started(t.conversation.id, t.conversation.subject)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SupportAttachmentStrip: View {
    @Binding var images: [UIImage]
    let accent: Color
    let add: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { images.remove(at: i) } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding(4).accessibilityLabel("Remove screenshot")
                        }
                }
                if images.count < 4 {
                    Button(action: add) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.title3)
                            Text("Screenshot").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(accent)
                        .frame(width: 96, height: 96)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }
}

// MARK: - Conversation

struct SupportThreadScreen: View {
    @StateObject private var model: SupportThreadModel
    let subject: String
    let accent: Color
    let back: () -> Void
    @State private var text = ""
    @State private var images: [UIImage] = []
    @State private var picking = false

    init(id: String, subject: String, accent: Color, back: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SupportThreadModel(id: id))
        self.subject = subject
        self.accent = accent
        self.back = back
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if !model.loaded { ProgressView().padding(.top, 30) }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, m in
                            if showsTime(i) {
                                Text(SupportText.time(m.date)).font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.top, 10)
                            }
                            SupportBubble(message: m, showsAuthor: showsAuthor(i), accent: accent)
                        }
                        ForEach(model.pending) { p in SupportPendingBubble(pending: p, accent: accent) { Task { await model.retry(p) } } }
                        if model.loaded, model.messages.last?.isFromCustomer == true, model.pending.isEmpty {
                            Text("We'll notify you when the team replies.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14).padding(.top, 72).padding(.bottom, 12)
                }
                .onChange(of: model.messages.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.pending.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            SupportTopBar(title: subject.isEmpty ? "Conversation" : subject, subtitle: AppReferSupport.shared.resolvedTitle, leadingSymbol: "chevron.left", leading: back) { EmptyView() }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .sheet(isPresented: $picking) { SupportPhotoPicker(limit: max(1, 4 - images.count)) { images.append(contentsOf: $0) } }
        .task { await model.load() }
        .task {
            // Replies arrive by polling only while this screen is open (and by push otherwise).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await model.poll()
            }
        }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    private var composer: some View {
        VStack(spacing: 8) {
            if !images.isEmpty { SupportAttachmentStrip(images: $images, accent: accent) { picking = true }.padding(.horizontal, 14) }
            HStack(alignment: .bottom, spacing: 10) {
                Button { picking = true } label: { Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 40, height: 40) }
                    .foregroundStyle(.primary).supportGlass().accessibilityLabel("Add screenshot")
                SupportMessageField(text: $text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .supportGlass(cornerRadius: 20)
                Button {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let imgs = images
                    text = ""
                    images = []
                    Task { await model.send(text: t, images: imgs) }
                } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(canSend ? accent : Color.gray.opacity(0.4), in: Circle())
                }
                .disabled(!canSend).accessibilityLabel("Send")
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }

    private func showsTime(_ i: Int) -> Bool {
        guard i > 0 else { return true }
        guard let a = model.messages[i - 1].date, let b = model.messages[i].date else { return false }
        return b.timeIntervalSince(a) > 3600
    }

    private func showsAuthor(_ i: Int) -> Bool {
        let m = model.messages[i]
        guard !m.isFromCustomer else { return false }
        return i == 0 || model.messages[i - 1].from != m.from || model.messages[i - 1].authorName != m.authorName
    }
}

struct SupportMessageField: View {
    @Binding var text: String
    var body: some View {
        if #available(iOS 16.0, *) {
            TextField("Message", text: $text, axis: .vertical).lineLimit(1...5)
        } else {
            TextField("Message", text: $text)
        }
    }
}

struct SupportBubble: View {
    let message: AppReferSupportMessage
    let showsAuthor: Bool
    let accent: Color

    private var mine: Bool { message.isFromCustomer }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if showsAuthor {
                Text(message.from == "bot" ? "\(AppReferSupport.shared.resolvedTitle) · instant answer" : (message.authorName.map { firstName($0) } ?? "Team"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            ForEach(message.attachments.filter(\.isImage), id: \.self) { a in
                if let s = a.url, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { Color(.tertiarySystemFill) }
                    }
                    .frame(width: 180, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel(a.name ?? "Screenshot")
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(mine ? Color.white : Color.primary)
                    .background(mine ? accent : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 48)
    }

    private func firstName(_ name: String) -> String {
        name.contains("@") ? "Team" : String(name.split(separator: " ").first ?? Substring(name))
    }
}

struct SupportPendingBubble: View {
    let pending: PendingMessage
    let accent: Color
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(Array(pending.images.enumerated()), id: \.offset) { _, image in
                Image(uiImage: image).resizable().scaledToFill().frame(width: 180, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).opacity(0.6)
            }
            if !pending.text.isEmpty {
                Text(pending.text).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(.white)
                    .background(accent.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            if pending.failed {
                Button("Not sent · Tap to retry", action: retry).font(.caption.weight(.semibold)).foregroundStyle(.red)
            } else {
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

// MARK: - Photos

struct SupportPhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let picked: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = limit
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let picked: ([UIImage]) -> Void
        init(picked: @escaping ([UIImage]) -> Void) { self.picked = picked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let providers = results.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
            guard !providers.isEmpty else { return }
            var images: [UIImage] = []
            let group = DispatchGroup()
            let lock = NSLock()
            for p in providers {
                group.enter()
                p.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage { lock.lock(); images.append(image); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [picked] in picked(images) }
        }
    }
}

extension View {
    @ViewBuilder
    func supportHideEditorBackground() -> some View {
        if #available(iOS 16.0, *) { self.scrollContentBackground(.hidden) } else { self }
    }
}
#endif
