#if os(iOS)
import SwiftUI

// MARK: - Home section

/// "Help articles" on the help home: a search entry and the first three articles.
/// Not shown at all when the app has no published articles.
struct SupportHelpSection: View {
    let articles: [AppReferHelpArticle]
    let palette: SupportPalette
    /// First card under the hero (no conversation to continue): it gets the hero card's lift.
    let prominent: Bool
    let open: (SupportRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SupportSectionLabel(text: SupportStrings.text("support.help.title"))
                Spacer(minLength: 8)
                if articles.count > 3 {
                    Button { open(.help(search: false)) } label: {
                        HStack(spacing: 3) {
                            Text(SupportStrings.text("support.help.seeAll"))
                            Image(systemName: "chevron.forward").font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(palette.accent)
                        .padding(.vertical, 4).padding(.leading, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { open(.help(search: true)) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold))
                    Text(SupportStrings.text("support.help.search.placeholder")).font(.system(size: 15.5)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(SupportColors.muted)
                .padding(.horizontal, 14).frame(height: 44)
                .background(SupportColors.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(SupportPressStyle())
            .accessibilityLabel(SupportStrings.text("support.help.search.placeholder"))
            .accessibilityAddTraits(.isSearchField)

            VStack(spacing: 0) {
                let top = Array(articles.prefix(3))
                ForEach(top) { article in
                    Button { open(.article(slug: article.slug, title: article.title)) } label: {
                        SupportArticleRow(article: article, palette: palette, summaryLines: SupportLines.homeSummary)
                    }
                    .buttonStyle(.plain)
                    if article.id != top.last?.id { Divider().padding(.leading, 48) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: SupportColors.shadow.opacity(prominent ? 0.22 : 0.07), radius: prominent ? 22 : 10, y: prominent ? 14 : 2)
    }
}

/// One article in a list: a document tile, the title and its summary.
struct SupportArticleRow: View {
    let article: AppReferHelpArticle
    let palette: SupportPalette
    var summaryLines = 2

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.accent)
                .frame(width: 36, height: 36)
                .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(article.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                    if article.isDraft { SupportDraftBadge() }
                }
                if !article.summary.isEmpty {
                    Text(article.summary).font(.system(size: 13.5)).foregroundStyle(SupportColors.muted).lineLimit(summaryLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 6)
            Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold)).foregroundStyle(SupportColors.muted.opacity(0.7))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SupportStrings.text("support.help.a11y.article", ["title": article.title]))
        .accessibilityHint(article.summary)
    }
}

struct SupportDraftBadge: View {
    var body: some View {
        Text(SupportStrings.text("support.help.draft").uppercased(with: SupportStrings.locale))
            .font(.system(size: 9.5, weight: .heavy)).tracking(0.4).foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Shared pieces

/// The floating glass bar at the top of the help screens (same as a conversation's).
struct SupportScreenHeader<Trailing: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.backward").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 42, height: 42).background(Color.primary.opacity(0.05), in: Circle())
            }
            .accessibilityLabel(SupportStrings.text("support.a11y.back"))
            Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 10).frame(height: 64)
        .supportGlass(cornerRadius: 32, tint: SupportColors.card.opacity(0.55))
        .shadow(color: SupportColors.shadow.opacity(0.14), radius: 16, y: 8)
        .padding(.horizontal, 12).padding(.top, 10)
    }
}

/// "Still need help?" with the team's reply time and a "Message us" button.
struct SupportStillNeedHelpCard: View {
    let palette: SupportPalette
    let action: () -> Void
    @ObservedObject private var personas = SupportPersonaStore.shared

    private var support: AppReferSupport { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let persona = personas.persona {
                    SupportAvatar(name: persona.name, size: 44, colors: [palette.warm, palette.hot], image: persona.avatar)
                } else {
                    SupportAvatar(name: support.teamNames.first, size: 44, colors: [palette.warm, palette.hot],
                                  symbol: support.teamNames.isEmpty ? "bubble.left.and.bubble.right.fill" : nil)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(SupportStrings.text("support.help.stillNeedHelp")).font(.system(size: 17, weight: .bold))
                    Text(subtitle).font(.system(size: 13.5)).foregroundStyle(SupportColors.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.fill").font(.system(size: 15, weight: .semibold))
                    Text(SupportStrings.text("support.help.messageUs")).font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(palette.bubble, in: Capsule())
                .shadow(color: palette.accent.opacity(0.3), radius: 12, y: 6)
            }
            .buttonStyle(SupportPressStyle())
        }
        .padding(18)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 2)
    }

    private var subtitle: String {
        if let persona = personas.persona {
            return SupportStrings.text("support.presence.persona", ["persona": persona.name, "time": support.replyTime])
        }
        return SupportStrings.text("support.presence.team", ["time": support.replyTime])
    }
}

// MARK: - Help centre

struct SupportHelpScreen: View {
    @StateObject private var model = SupportHelpModel()
    let palette: SupportPalette
    let focusSearch: Bool
    let back: () -> Void
    let open: (SupportRoute) -> Void
    let messageUs: (String?) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    searchField
                    content
                    if model.loaded || !model.all.isEmpty {
                        SupportStillNeedHelpCard(palette: palette) { messageUs(nil) }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 86).padding(.bottom, 32)
            }
            .supportDismissKeyboardOnScroll()
            SupportScreenHeader(title: SupportStrings.text("support.help.title"), back: back) { EmptyView() }
        }
        .task { await model.load() }
        .onAppear {
            // After the push animation, so the keyboard doesn't fight it.
            if focusSearch { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { searchFocused = true } }
        }
        .onChange(of: model.query) { model.search($0) }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(SupportColors.muted)
            TextField(SupportStrings.text("support.help.search.placeholder"), text: $model.query)
                .font(.system(size: 16))
                .focused($searchFocused)
                .submitLabel(.search)
                .disableAutocorrection(true)
                .accessibilityIdentifier("HelpSearch")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(SupportColors.muted.opacity(0.8))
                }
                .accessibilityLabel(SupportStrings.text("support.help.a11y.clearSearch"))
            }
        }
        .padding(.horizontal, 14).frame(height: 50)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.accent.opacity(searchFocused ? 0.45 : 0), lineWidth: 1.5))
        .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 2)
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    @ViewBuilder private var content: some View {
        if let results = model.results {
            if !results.isEmpty {
                list(results)
            } else if model.searching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(SupportStrings.text("support.help.searching")).font(.system(size: 14)).foregroundStyle(SupportColors.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                noResults
            }
        } else if model.all.isEmpty {
            if model.loaded && model.failed {
                VStack(spacing: 12) {
                    Text(SupportStrings.text("support.help.listFailed")).font(.system(size: 15)).foregroundStyle(SupportColors.muted)
                    Button(SupportStrings.text("support.action.tryAgain")) { Task { await model.load() } }
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if !model.loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        } else {
            ForEach(Array(SupportHelpModel.groups(model.all).enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 10) {
                    if let title = group.title { SupportSectionLabel(text: title).padding(.leading, 6) }
                    list(group.articles)
                }
            }
        }
    }

    private func list(_ articles: [AppReferHelpArticle]) -> some View {
        VStack(spacing: 0) {
            ForEach(articles) { article in
                Button { open(.article(slug: article.slug, title: article.title)) } label: {
                    SupportArticleRow(article: article, palette: palette).padding(.horizontal, 14)
                }
                .buttonStyle(.plain)
                if article.id != articles.last?.id { Divider().padding(.leading, 62) }
            }
        }
        .padding(.vertical, 4)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 2)
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(palette.accent)
                .frame(width: 56, height: 56).background(palette.accent.opacity(0.12), in: Circle())
            Text(SupportStrings.text("support.help.search.noResults", ["query": SupportAPI.normalizedQuery(model.query) ?? ""]))
                .font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center)
            Text(SupportStrings.text("support.help.search.noResultsHint"))
                .font(.system(size: 14)).foregroundStyle(SupportColors.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 12)
    }
}

// MARK: - Article

struct SupportArticleScreen: View {
    @StateObject private var model: SupportArticleModel
    let initialTitle: String
    let palette: SupportPalette
    let back: () -> Void
    let messageUs: (String?) -> Void
    @Environment(\.openURL) private var openURL

    init(slug: String, title: String, palette: SupportPalette, back: @escaping () -> Void, messageUs: @escaping (String?) -> Void) {
        _model = StateObject(wrappedValue: SupportArticleModel(slug: slug))
        self.initialTitle = title
        self.palette = palette
        self.back = back
        self.messageUs = messageUs
    }

    private var title: String { model.detail?.title ?? initialTitle }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let category = model.detail?.category {
                        Text(category.uppercased(with: SupportStrings.locale))
                            .font(.system(size: 12, weight: .bold)).tracking(0.6).foregroundStyle(palette.accent)
                            .padding(.bottom, 8)
                    }
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: 28, weight: .heavy)).tracking(-0.6)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let detail = model.detail { meta(detail).padding(.top, 8) }
                    Group {
                        if model.detail != nil {
                            SupportMarkdownView(blocks: model.blocks, palette: palette)
                                .padding(20)
                                .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                                .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 2)
                        } else if model.failed {
                            failure
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(SupportStrings.text("support.help.loading")).font(.system(size: 14)).foregroundStyle(SupportColors.muted)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                        }
                    }
                    .padding(.top, 20)
                    SupportStillNeedHelpCard(palette: palette) { messageUs(title.isEmpty ? nil : title) }
                        .padding(.top, 24)
                }
                .padding(.horizontal, 16).padding(.top, 86).padding(.bottom, 32)
            }
            SupportScreenHeader(title: SupportStrings.text("support.help.title"), back: back) {
                if let url = model.detail?.article.webURL {
                    Button { openURL(url) } label: {
                        Image(systemName: "safari").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                            .frame(width: 42, height: 42).background(Color.primary.opacity(0.05), in: Circle())
                    }
                    .accessibilityLabel(SupportStrings.text("support.help.openInBrowser"))
                }
            }
        }
        .task { await model.load() }
    }

    private func meta(_ detail: AppReferHelpArticleDetail) -> some View {
        HStack(spacing: 8) {
            if let date = detail.article.updatedDate {
                Text(SupportStrings.text("support.help.updated", ["date": SupportText.day(date)]))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(SupportColors.muted)
            }
            if detail.isDraft { SupportDraftBadge() }
        }
    }

    private var failure: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(palette.accent)
                .frame(width: 56, height: 56).background(palette.accent.opacity(0.12), in: Circle())
            Text(SupportStrings.text("support.help.loadFailed")).font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center)
            Button(SupportStrings.text("support.action.tryAgain")) { Task { await model.load() } }
                .font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

// MARK: - Markdown

/// Renders parsed article blocks. Links open in the browser (only http(s) and mailto
/// survive parsing); nothing in an article can run code.
struct SupportMarkdownView: View {
    let blocks: [SupportMarkdownBlock]
    let palette: SupportPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(block).padding(.top, i == 0 ? 0 : spacing(blocks[i - 1], block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .modifier(SupportSafeLinks())
    }

    private func spacing(_ previous: SupportMarkdownBlock, _ block: SupportMarkdownBlock) -> CGFloat {
        switch (previous, block) {
        case (.listItem, .listItem): return 7
        case (.heading, _): return 8
        case (_, .heading): return 22
        default: return 14
        }
    }

    @ViewBuilder private func view(_ block: SupportMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(.system(size: level == 1 ? 23 : level == 2 ? 20 : level == 3 ? 17 : 15.5, weight: level <= 2 ? .bold : .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(text).font(.system(size: 16)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case let .listItem(number, depth, text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if let number {
                        Text(verbatim: "\(number).").font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(palette.accent)
                    } else {
                        Circle().fill(palette.accent.opacity(depth == 0 ? 1 : 0.5)).frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    }
                }
                .frame(minWidth: number == nil ? 8 : 20, alignment: .trailing)
                Text(text).font(.system(size: 16)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(depth) * 20)
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(palette.accent.opacity(0.6)).frame(width: 4)
                Text(text).font(.system(size: 15.5)).italic().foregroundStyle(SupportColors.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code).font(.system(size: 13.5, design: .monospaced)).lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .environment(\.layoutDirection, .leftToRight)
        case .rule:
            Divider().padding(.vertical, 4)
        case let .image(url, alt):
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    EmptyView()
                } else {
                    Color.primary.opacity(0.05).frame(height: 160)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel(alt.isEmpty ? SupportStrings.text("support.a11y.screenshot") : alt)
        }
    }
}

/// Links in an article open outside the app, and only http(s) and mailto ones (already
/// the only ones left after parsing; this also guards against anything else on iOS 16+).
struct SupportSafeLinks: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.environment(\.openURL, OpenURLAction { url in
                SupportMarkdown.safeURL(url.absoluteString) == nil ? .discarded : .systemAction
            })
        } else {
            content
        }
    }
}
#endif
