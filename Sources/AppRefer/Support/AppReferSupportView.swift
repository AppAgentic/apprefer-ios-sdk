#if os(iOS)
import SwiftUI
import PhotosUI

/// The whole help chat: home and conversations. Use `AppRefer.support.open()`
/// to present it, or embed this view yourself.
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

    /// Opens on the message field, optionally pre-filled.
    public init(composing draft: String) {
        self.initialConversation = nil
        self.initialDraft = draft
    }

    private var palette: SupportPalette { SupportPalette(AppReferSupport.shared.accentColor ?? .accentColor) }

    public var body: some View {
        ZStack {
            SupportHomeScreen(model: home, palette: palette, draft: initialDraft, close: { dismiss() }, push: push)
            ForEach(Array(path.enumerated()), id: \.element) { index, route in
                Group {
                    switch route {
                    case let .thread(id, subject):
                        SupportThreadScreen(id: id, subject: subject, palette: palette, back: pop)
                    }
                }
                .background(SupportColors.background.ignoresSafeArea())
                .transition(.move(edge: .trailing))
                .zIndex(Double(index + 1))
            }
        }
        .tint(palette.accent)
        .task {
            if let initialConversation, path.isEmpty { path = [.thread(id: initialConversation, subject: "")] }
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

// MARK: - Home

struct SupportHomeScreen: View {
    @ObservedObject var model: SupportHomeModel
    let palette: SupportPalette
    let close: () -> Void
    let push: (SupportRoute) -> Void

    @State private var text: String
    @State private var images: [UIImage] = []
    @State private var topic: AppReferSupportTopic?
    @State private var picking = false
    @State private var sending = false
    @State private var error: String?
    /// The same on every retry of this message.
    @State private var clientMessageId = UUID().uuidString
    @FocusState private var focused: Bool
    private let startsFocused: Bool

    init(model: SupportHomeModel, palette: SupportPalette, draft: String?, close: @escaping () -> Void, push: @escaping (SupportRoute) -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.palette = palette
        self.close = close
        self.push = push
        self.startsFocused = draft != nil
        _text = State(initialValue: draft ?? "")
    }

    private var support: AppReferSupport { .shared }

    var body: some View {
        ZStack(alignment: .bottom) {
            SupportColors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    VStack(alignment: .leading, spacing: 24) {
                        if let current = model.current { continueCard(current) }
                        if !support.topics.isEmpty { quickHelp }
                        if !model.others.isEmpty { pastConversations }
                        if !model.loaded && model.conversations.isEmpty {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                        if let error = model.error, model.conversations.isEmpty {
                            Text(error).font(.footnote).foregroundStyle(SupportColors.muted)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, -62)
                    .padding(.bottom, 140)
                }
            }
            .coordinateSpace(name: "home")
            .supportDismissKeyboardOnScroll()

            VStack(spacing: 8) {
                if let error { SupportErrorLine(text: error) }
                if let topic { topicChip(topic) }
                SupportComposerBar(
                    text: $text, images: $images, focus: $focused,
                    placeholder: topic?.prompt ?? "Ask us anything…", leadingSymbol: "camera.fill",
                    palette: palette, sending: sending, pick: { picking = true }, send: { Task { await start() } }
                )
            }
        }
        .sheet(isPresented: $picking) { SupportPhotoPicker(limit: max(1, 4 - images.count)) { images.append(contentsOf: $0.prefix(max(0, 4 - images.count))) } }
        .onAppear { if startsFocused { focused = true } }
        .task { await model.refresh() }
        .task {
            // Keep the list fresh while the help screen is open; nothing runs once it closes.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if UIApplication.shared.applicationState == .active { await model.refresh() }
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                appIcon
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(palette.onAccent).frame(width: 40, height: 40)
                }
                .supportGlass(tint: palette.onAccent.opacity(0.12))
                .accessibilityLabel("Close")
            }
            Text(support.resolvedTitle)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.onAccent.opacity(0.85))
                .padding(.top, 20)
            Text(greeting)
                .font(.system(size: 38, weight: .heavy)).tracking(-1).foregroundStyle(palette.onAccent)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top, 2)
            Text("How can we help today?")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(palette.onAccent.opacity(0.92))
                .padding(.top, 2)
            presence.padding(.top, 18)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 62 + 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Stretches when pulled down, so the colour never ends in a gap.
            GeometryReader { g in
                let pull = max(0, g.frame(in: .named("home")).minY)
                SupportHeroBackground(palette: palette)
                    .frame(height: g.size.height + pull)
                    .offset(y: -pull)
            }
        )
    }

    private var greeting: String {
        if let first = SupportText.firstName(model.name) { return "Hi \(first) 👋" }
        return "Hi there 👋"
    }

    @ViewBuilder private var appIcon: some View {
        if let icon = support.resolvedIcon {
            Image(uiImage: icon).resizable().scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 6)
                .accessibilityHidden(true)
        } else {
            Text(String(support.appName.prefix(2)).uppercased())
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.light)
                .frame(width: 46, height: 46)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.36), Color(red: 0.06, green: 0.04, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 6)
                .accessibilityHidden(true)
        }
    }

    private var presence: some View {
        let names = Array(support.teamNames.prefix(3))
        let line: String = {
            guard let first = names.first else { return "We usually reply in \(support.replyTime)" }
            return names.count == 1 && support.teamNames.count == 1
                ? "\(first) · usually replies in \(support.replyTime)"
                : "\(first) and the team · usually \(support.replyTime)"
        }()
        return HStack(spacing: 10) {
            HStack(spacing: -8) {
                if names.isEmpty {
                    SupportAvatar(name: nil, size: 28, colors: [palette.warm, palette.hot], symbol: "bubble.left.fill")
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                } else {
                    ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                        SupportAvatar(name: name, size: 28, colors: avatarColors(i))
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                            .zIndex(Double(names.count - i))
                    }
                }
            }
            Text(line).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.onAccent).lineLimit(2).minimumScaleFactor(0.85)
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 7)
        // A darker wash, not white glass: the hero is light at the edges and white text must stay readable.
        .background(Color.black.opacity(palette.onAccent == .white ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(palette.onAccent.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func avatarColors(_ i: Int) -> [Color] {
        switch i % 3 {
        case 0: return [palette.warm, palette.hot]
        case 1: return [Color(red: 0.36, green: 0.68, blue: 1), Color(red: 0.18, green: 0.45, blue: 0.95)]
        default: return [Color(white: 0.3), Color(white: 0.08)]
        }
    }

    // MARK: Cards

    private func continueCard(_ c: AppReferSupportConversation) -> some View {
        Button { push(.thread(id: c.id, subject: c.subject)) } label: {
            VStack(alignment: .leading, spacing: 12) {
                SupportSectionLabel(text: "Continue")
                HStack(spacing: 12) {
                    SupportAvatar(name: support.teamNames.first, size: 46, colors: [palette.warm, palette.hot], symbol: support.teamNames.isEmpty ? "bubble.left.and.bubble.right.fill" : nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.subject).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        Text(c.lastFrom == "customer" ? "You: \(c.preview)" : c.preview)
                            .font(.system(size: 14)).foregroundStyle(SupportColors.muted).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if c.unread > 0 {
                        Text("\(c.unread)").font(.system(size: 12, weight: .bold)).foregroundStyle(palette.onAccent)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(palette.accent, in: Capsule())
                            .accessibilityLabel("\(c.unread) unread")
                    } else {
                        Text(SupportText.time(SupportDates.parse(c.lastMessageAt))).font(.caption).foregroundStyle(SupportColors.muted)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: SupportColors.shadow.opacity(0.22), radius: 22, y: 14)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(SupportPressStyle())
    }

    private var quickHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.current != nil { SupportSectionLabel(text: "Quick help").padding(.leading, 6) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(support.topics) { t in
                    Button { pick(t) } label: { tile(t) }.buttonStyle(SupportPressStyle())
                }
            }
        }
    }

    private func tile(_ t: AppReferSupportTopic) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: t.systemImage)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(t.tint)
                .frame(width: 34, height: 34)
                .background(t.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(.bottom, 10)
            Text(t.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
            Text(t.subtitle).font(.system(size: 12.5)).foregroundStyle(SupportColors.muted).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var pastConversations: some View {
        VStack(alignment: .leading, spacing: 10) {
            SupportSectionLabel(text: "Your conversations").padding(.leading, 6)
            VStack(spacing: 0) {
                ForEach(model.others) { c in
                    Button { push(.thread(id: c.id, subject: c.subject)) } label: { row(c) }.buttonStyle(.plain)
                    if c.id != model.others.last?.id { Divider().padding(.leading, 64) }
                }
            }
            .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 2)
        }
    }

    private func row(_ c: AppReferSupportConversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: c.isOpen ? "bubble.left.fill" : "checkmark")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(palette.accent)
                .frame(width: 40, height: 40).background(palette.accent.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(c.subject).font(.system(size: 15, weight: c.unread > 0 ? .semibold : .regular)).lineLimit(1)
                Text(c.preview).font(.system(size: 13.5)).foregroundStyle(SupportColors.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if c.unread > 0 {
                Text("\(c.unread)").font(.caption.weight(.bold)).foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(palette.accent, in: Capsule())
                    .accessibilityLabel("\(c.unread) unread")
            } else {
                Text(SupportText.time(SupportDates.parse(c.lastMessageAt))).font(.caption).foregroundStyle(SupportColors.muted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: Starting a conversation

    private func topicChip(_ t: AppReferSupportTopic) -> some View {
        HStack(spacing: 6) {
            Image(systemName: t.systemImage).font(.system(size: 12, weight: .bold))
            Text(t.title).font(.system(size: 14, weight: .semibold))
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { topic = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).padding(4)
            }
            .accessibilityLabel("Remove topic")
        }
        .foregroundStyle(t.tint)
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(SupportColors.card, in: Capsule())
        .overlay(Capsule().stroke(t.tint.opacity(0.25), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func pick(_ t: AppReferSupportTopic) {
        if let action = t.action { action(); return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { topic = t }
        focused = true
    }

    private func start() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            let sentText = text
            var ids: [String] = []
            for image in images { ids.append(try await SupportAPI.shared.upload(await SupportImages.jpegOffMain(image))) }
            let body = sentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = try await SupportAPI.shared.start(text: body, subject: topic?.title, attachmentIds: ids, clientMessageId: clientMessageId)
            // Anything typed while it was sending stays in the field.
            text = text.hasPrefix(sentText) ? String(text.dropFirst(sentText.count)) : text
            images = []
            topic = nil
            focused = false
            clientMessageId = UUID().uuidString
            push(.thread(id: t.conversation.id, subject: t.conversation.subject))
            await model.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SupportHeroBackground: View {
    let palette: SupportPalette
    var body: some View {
        ZStack {
            palette.accent
            RadialGradient(colors: [palette.light, palette.light.opacity(0)], center: UnitPoint(x: 0.1, y: 0), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [palette.hot, palette.hot.opacity(0)], center: UnitPoint(x: 1, y: 0.2), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [palette.warm.opacity(0.95), palette.warm.opacity(0)], center: UnitPoint(x: 0.6, y: 1.05), startRadius: 0, endRadius: 340)
        }
        .accessibilityHidden(true)
    }
}

struct SupportSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .bold)).tracking(0.6).foregroundStyle(SupportColors.muted)
    }
}

struct SupportErrorLine: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote.weight(.medium)).foregroundStyle(.red)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(SupportColors.card, in: Capsule())
            .padding(.horizontal, 18)
    }
}

struct SupportPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Composer

/// The floating glass bar used on the home and in a conversation.
struct SupportComposerBar: View {
    @Binding var text: String
    @Binding var images: [UIImage]
    var focus: FocusState<Bool>.Binding
    let placeholder: String
    let leadingSymbol: String
    let palette: SupportPalette
    var sending = false
    let pick: () -> Void
    let send: () -> Void

    private var canSend: Bool { !sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) }

    var body: some View {
        VStack(spacing: 8) {
            if !images.isEmpty {
                SupportAttachmentStrip(images: $images, palette: palette, add: pick).padding(.horizontal, 18)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Button(action: pick) {
                    Image(systemName: leadingSymbol).font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SupportColors.muted).frame(width: 44, height: 44)
                }
                .disabled(images.count >= 4 || sending)
                .opacity(images.count >= 4 ? 0.4 : 1)
                .accessibilityLabel("Add screenshot")
                SupportMessageField(text: $text, placeholder: placeholder, focus: focus)
                    .font(.system(size: 17))
                    .padding(.vertical, 11)
                Button(action: send) {
                    ZStack {
                        Circle().fill(canSend ? AnyShapeStyle(palette.bubble) : AnyShapeStyle(Color.gray.opacity(0.3)))
                        if sending { ProgressView().tint(palette.onAccent) } else {
                            Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(canSend ? palette.onAccent : .white)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 6).padding(.trailing, 7).padding(.vertical, 7)
            .supportGlass(cornerRadius: 29, tint: SupportColors.card.opacity(0.55))
            .shadow(color: SupportColors.shadow.opacity(0.18), radius: 20, y: 10)
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: images.count)
    }
}

struct SupportMessageField: View {
    @Binding var text: String
    let placeholder: String
    var focus: FocusState<Bool>.Binding
    var body: some View {
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: $text, axis: .vertical).lineLimit(1...5).focused(focus)
                .accessibilityIdentifier("Message")
        } else {
            TextField(placeholder, text: $text).focused(focus).accessibilityIdentifier("Message")
        }
    }
}

struct SupportAttachmentStrip: View {
    @Binding var images: [UIImage]
    let palette: SupportPalette
    let add: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 62, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                        .overlay(alignment: .topTrailing) {
                            Button { images.remove(at: i) } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6).accessibilityLabel("Remove screenshot")
                        }
                }
                if images.count < 4 {
                    Button(action: add) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(palette.accent)
                            .frame(width: 62, height: 88)
                            .background(SupportColors.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityLabel("Add another screenshot")
                }
            }
            .padding(.vertical, 8).padding(.trailing, 8)
        }
    }
}

// MARK: - Conversation

struct SupportThreadScreen: View {
    @StateObject private var model: SupportThreadModel
    let subject: String
    let palette: SupportPalette
    let back: () -> Void
    @State private var text = ""
    @State private var images: [UIImage] = []
    @State private var picking = false
    @State private var viewing: SupportViewedImage?
    @FocusState private var focused: Bool

    init(id: String, subject: String, palette: SupportPalette, back: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SupportThreadModel(id: id))
        self.subject = subject
        self.palette = palette
        self.back = back
    }

    private var support: AppReferSupport { .shared }

    /// The person answering: the newest team reply's author.
    private var agent: String? {
        model.messages.last { $0.from == "team" && SupportText.firstName($0.authorName) != nil }.flatMap { SupportText.firstName($0.authorName) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !model.loaded { ProgressView().padding(.top, 30) }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, m in
                            if showsTime(i) {
                                Text(SupportText.time(m.date)).font(.system(size: 12, weight: .semibold)).foregroundStyle(SupportColors.muted)
                                    .padding(.top, i == 0 ? 4 : 16).padding(.bottom, 8)
                            }
                            message(i, m).padding(.top, i > 0 && !showsTime(i) ? (sameSide(i - 1, i) ? 3 : 10) : 0)
                        }
                        ForEach(model.pending) { p in
                            SupportPendingBubble(pending: p, palette: palette) { Task { await model.retry(p) } }.padding(.top, 6)
                        }
                        if model.loaded, model.pending.isEmpty, let last = model.messages.last, last.isFromCustomer {
                            Text("Sent \(SupportText.clock(last.date)) · we'll notify you when the team replies")
                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(SupportColors.muted)
                                .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 5).padding(.trailing, 4)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14).padding(.top, 86).padding(.bottom, 12)
                }
                .supportDismissKeyboardOnScroll()
                .onChange(of: model.messages.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.pending.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            header
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if showsQuickReplies { quickReplies }
                SupportComposerBar(
                    text: $text, images: $images, focus: $focused,
                    placeholder: "Message", leadingSymbol: "plus", palette: palette,
                    pick: { picking = true }, send: sendTyped
                )
            }
        }
        .sheet(isPresented: $picking) { SupportPhotoPicker(limit: max(1, 4 - images.count)) { images.append(contentsOf: $0.prefix(max(0, 4 - images.count))) } }
        .supportImageViewer($viewing)
        .task { await model.load() }
        .task {
            // Replies arrive by polling only while this screen is open and the app is
            // active (and by push otherwise). The app's state, not scenePhase: this view
            // is usually hosted by UIKit, where scenePhase isn't reliable.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if UIApplication.shared.applicationState == .active { await model.poll() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 42, height: 42).background(Color.primary.opacity(0.05), in: Circle())
            }
            .accessibilityLabel("Back")
            SupportAvatar(name: agent, size: 42, colors: [palette.warm, palette.hot], symbol: agent == nil ? "bubble.left.and.bubble.right.fill" : nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent ?? "\(support.appName) team").font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text("Usually replies in \(support.replyTime)")
                    .font(.system(size: 12.5)).foregroundStyle(SupportColors.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 64)
        .supportGlass(cornerRadius: 32, tint: SupportColors.card.opacity(0.55))
        .shadow(color: SupportColors.shadow.opacity(0.14), radius: 16, y: 8)
        .padding(.horizontal, 12).padding(.top, 10)
    }

    @ViewBuilder
    private func message(_ i: Int, _ m: AppReferSupportMessage) -> some View {
        let lastOfGroup = i == model.messages.count - 1 || !sameSide(i, i + 1) || showsTime(i + 1)
        if m.isFromCustomer {
            SupportCustomerBubble(message: m, palette: palette, tail: lastOfGroup, view: { viewing = $0 })
        } else if m.from == "bot" {
            SupportBotCard(message: m, palette: palette)
        } else {
            SupportTeamBubble(message: m, palette: palette, avatar: lastOfGroup, view: { viewing = $0 })
        }
    }

    private var showsQuickReplies: Bool {
        model.loaded && model.pending.isEmpty && text.isEmpty && images.isEmpty && (model.messages.last.map { !$0.isFromCustomer } ?? false)
    }

    private var quickReplies: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("👍 Thanks, that's sorted") { Task { await model.send(text: "👍 Thanks, that's sorted", images: []) } }
                chip("I have another question") { focused = true }
            }
            .padding(.horizontal, 14)
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.accent)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(SupportColors.card, in: Capsule())
                .overlay(Capsule().stroke(palette.accent.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(SupportPressStyle())
    }

    private func sendTyped() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = images
        text = ""
        images = []
        Task { await model.send(text: t, images: imgs) }
    }

    private func sameSide(_ a: Int, _ b: Int) -> Bool {
        guard model.messages.indices.contains(a), model.messages.indices.contains(b) else { return false }
        return model.messages[a].isFromCustomer == model.messages[b].isFromCustomer && model.messages[a].from == model.messages[b].from
    }

    private func showsTime(_ i: Int) -> Bool {
        guard model.messages.indices.contains(i) else { return false }
        guard i > 0 else { return true }
        guard let a = model.messages[i - 1].date, let b = model.messages[i].date else { return false }
        return b.timeIntervalSince(a) > 3600
    }
}

struct SupportViewedImage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SupportThumbnail: View {
    let attachment: AppReferSupportAttachment
    let view: (SupportViewedImage) -> Void

    var body: some View {
        if let s = attachment.url, let url = URL(string: s) {
            Button { view(SupportViewedImage(url: url)) } label: {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Color(.tertiarySystemFill) }
                }
                .frame(width: 74, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
            }
            .accessibilityLabel(attachment.name ?? "Screenshot")
        }
    }
}

/// Screenshots in rows of two, so four never overflow a narrow phone.
struct SupportThumbnailRows: View {
    let attachments: [AppReferSupportAttachment]
    var alignment: HorizontalAlignment = .leading
    let view: (SupportViewedImage) -> Void

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            ForEach(Array(stride(from: 0, to: attachments.count, by: 2)), id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(attachments[i..<min(i + 2, attachments.count)], id: \.self) { SupportThumbnail(attachment: $0, view: view) }
                }
            }
        }
    }
}

struct SupportCustomerBubble: View {
    let message: AppReferSupportMessage
    let palette: SupportPalette
    let tail: Bool
    let view: (SupportViewedImage) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let images = message.attachments.filter(\.isImage)
            if !images.isEmpty {
                SupportThumbnailRows(attachments: images, alignment: .trailing, view: view)
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 16)).lineSpacing(2)
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(palette.bubble, in: SupportBubbleShape(bottomTrailing: tail ? 6 : 22))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
    }
}

struct SupportTeamBubble: View {
    let message: AppReferSupportMessage
    let palette: SupportPalette
    let avatar: Bool
    let view: (SupportViewedImage) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if avatar { SupportAvatar(name: SupportText.firstName(message.authorName), size: 30, colors: [palette.warm, palette.hot]) }
                else { Color.clear }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                let images = message.attachments.filter(\.isImage)
                if !images.isEmpty {
                    SupportThumbnailRows(attachments: images, view: view)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 16)).lineSpacing(2)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .background(SupportColors.card, in: SupportBubbleShape(bottomLeading: avatar ? 6 : 22))
                        .shadow(color: SupportColors.shadow.opacity(0.06), radius: 8, y: 2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 40)
        }
    }
}

struct SupportBotCard: View {
    let message: AppReferSupportMessage
    let palette: SupportPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("✦ Instant answer".uppercased()).font(.system(size: 11.5, weight: .bold)).tracking(0.4).foregroundStyle(palette.accent)
            Text(message.text).font(.system(size: 15.5)).lineSpacing(2).foregroundStyle(.primary).textSelection(.enabled)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: SupportColors.shadow.opacity(0.06), radius: 10, y: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 50)
    }
}

struct SupportPendingBubble: View {
    let pending: PendingMessage
    let palette: SupportPalette
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if !pending.images.isEmpty {
                LazyVGrid(columns: [GridItem(.fixed(74), spacing: 6), GridItem(.fixed(74), spacing: 6)], alignment: .trailing, spacing: 6) {
                    ForEach(Array(pending.images.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 74, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white, lineWidth: 3))
                    }
                }
                .opacity(0.6)
            }
            if !pending.text.isEmpty {
                Text(pending.text).font(.system(size: 16)).foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(palette.bubble, in: SupportBubbleShape(bottomTrailing: 6))
                    .opacity(0.6)
            }
            if pending.failed {
                Button("Not sent · Tap to retry", action: retry).font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
            } else {
                Text("Sending…").font(.system(size: 11.5, weight: .medium)).foregroundStyle(SupportColors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
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
            let providers = results.map(\.itemProvider).filter { $0.hasItemConformingToTypeIdentifier("public.image") }
            guard !providers.isEmpty else { return }
            var images: [UIImage] = []
            let group = DispatchGroup()
            let lock = NSLock()
            // Each photo is read from its file and decoded straight to 1600 px, one at a
            // time per provider, so a huge panorama never sits in memory at full size.
            for p in providers {
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: "public.image") { url, _ in
                    if let url, let image = SupportImages.downsampled(url) { lock.lock(); images.append(image); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [picked] in picked(images) }
        }
    }
}

extension View {
    @ViewBuilder
    func supportDismissKeyboardOnScroll() -> some View {
        if #available(iOS 16.0, *) { self.scrollDismissesKeyboard(.interactively) } else { self }
    }

    /// Full-screen view of a screenshot; tap to close.
    func supportImageViewer(_ item: Binding<SupportViewedImage?>) -> some View {
        fullScreenCover(item: item) { viewed in
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: viewed.url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { ProgressView().tint(.white) }
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { item.wrappedValue = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40)
                }
                .supportGlass()
                .padding(16)
                .accessibilityLabel("Close")
            }
            .onTapGesture { item.wrappedValue = nil }
        }
    }
}
#endif
