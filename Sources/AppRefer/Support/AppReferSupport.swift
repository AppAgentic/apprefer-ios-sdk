#if os(iOS)
import SwiftUI
import UIKit

/// AppRefer Support: an in-app help chat your team answers from the AppRefer
/// inbox. One line to add:
///
/// ```swift
/// Button("Help") { AppRefer.support.open() }
/// ```
///
/// Optional: `AppRefer.support.identify(name:email:)` (the app user id set
/// with `AppRefer.setUserId` is sent automatically), and for reply
/// notifications `AppRefer.support.registerDeviceToken(_:)` plus
/// `AppRefer.support.handleNotification(_:)`.
@MainActor
public final class AppReferSupport {
    public static let shared = AppReferSupport()

    /// Bubble and button colour. Defaults to the app's accent colour.
    public var accentColor: Color?
    /// Header title. Defaults to "<App name> support" in the chat's language.
    public var title: String?
    /// How fast the team usually answers, completing "We usually reply in …". Defaults to
    /// "under an hour" in the chat's language. A value you set is used as written in every
    /// language, so set it for the language your app is showing; in most languages the
    /// sentence around it leaves out "in" (e.g. German "innerhalb einer Stunde").
    public var replyTime: String {
        get { customReplyTime ?? SupportStrings.text("support.replyTime.default") }
        set { customReplyTime = newValue }
    }
    private var customReplyTime: String?
    /// Your own text for any of the chat's strings, by key (e.g.
    /// `["support.home.subtitle": "What's up?"]`). Used before the SDK's translations, in
    /// every language. Placeholders such as `{name}` are filled in; plural keys take
    /// `"key#one"`, `"key#few"`, … or just `"key"` for every count. Keys:
    /// `Localization/support-strings.json` in the SDK repo.
    public var strings: [String: String] {
        get { SupportStrings.overrides }
        set { SupportStrings.overrides = newValue }
    }
    /// Forces the chat's language (e.g. "de", "pt-BR", "zh-Hant"). By default it follows the
    /// language your app is running in, then the device's languages, then English.
    public var language: String? {
        get { SupportStrings.forcedLanguage }
        set { SupportStrings.forcedLanguage = newValue }
    }
    /// First names of the people who answer (e.g. `["Jay"]`), shown on the help home.
    public var teamNames: [String] = []
    /// The quick-help tiles on the home screen. Empty hides them.
    public var topics: [AppReferSupportTopic] = AppReferSupportTopic.defaults
    /// The icon on the home screen. Defaults to the app icon.
    public var appIcon: UIImage?
    /// Forces the APNs environment reply tokens are registered for. nil (the default) reads
    /// it from the app's signing: sandbox for development-signed builds (Debug or Release)
    /// and the Simulator, production for App Store, TestFlight, Ad Hoc and Enterprise builds.
    public var pushEnvironment: AppReferPushEnvironment? {
        get { PushEnvironmentSetting.shared.override }
        set { PushEnvironmentSetting.shared.override = newValue }
    }
    /// The environment `registerDeviceToken` and `status().pushReady` use.
    public var effectivePushEnvironment: AppReferPushEnvironment { PushEnvironmentSetting.shared.effective }

    private weak var presented: UIViewController?

    private var activationObserver: NSObjectProtocol?
    private init() {
        activationObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task { await SupportAPI.shared.retryRevocations() }
        }
    }

    /// Start Support without attribution, device signals or product analytics.
    public func configure(apiKey: String) async {
        await SupportAPI.shared.configure(apiKey: apiKey)
    }

    func dismissForReset() {
        SupportAccountState.shared.reset()
        SupportPersonaStore.shared.clear()
        presented?.dismiss(animated: false)
        presented = nil
    }

    /// Removes the account from Support without a full reset, e.g. when the user withdraws
    /// consent: forgets the name, email and app user id, revokes the current Support session
    /// and starts a new anonymous one. Conversations from the old session stay in your team
    /// inbox but are no longer shown in the app. The app user id is not sent to Support again
    /// until it changes (another account signs in) or `AppRefer.reset()` runs. Attribution,
    /// Billing and the stored user id are untouched.
    public func clearIdentity() async {
        dismissForReset()
        await SupportAPI.shared.clearIdentity()
        Task { await SupportAPI.shared.retryRevocations() }
    }

    /// Who the customer is, so the team can greet them and reply by email.
    public func identify(name: String? = nil, email: String? = nil) {
        let epoch = SupportAPI.shared.actionGeneration
        Task { await SupportAPI.shared.setIdentity(name: name, email: email, generation: epoch) }
    }

    /// Opens the help chat straight on a new message, optionally pre-filled
    /// (e.g. a "Report a problem" button).
    public func compose(_ text: String = "") {
        present(AppReferSupportView(composing: text))
    }

    /// Opens the help chat over the current screen, optionally on one conversation.
    public func open(conversationId: String? = nil) {
        present(AppReferSupportView(conversationId: conversationId))
    }

    /// Opens the help chat on one help article (e.g. from a "How does this work?" link).
    /// Back leads to the help home; "Message us" starts a conversation about the article.
    public func open(article slug: String) {
        present(AppReferSupportView(opening: .article(slug)))
    }

    /// Opens the help chat on the help centre: every article, with search.
    public func openHelpCentre() {
        present(AppReferSupportView(opening: .helpCentre))
    }

    // MARK: Help centre and status

    /// The app's published help articles in the chat's language (`language`, else the app's
    /// language), best first; with `query`, search results (titles, summaries and bodies, up
    /// to 20). Test SDK keys (`pk_test_`) also get drafts (`isDraft`). Lists are kept in
    /// memory for five minutes; if a request fails, the last list for the same query is
    /// returned, and only without one is the error thrown.
    public func articles(query: String? = nil) async throws -> [AppReferHelpArticle] {
        try await SupportAPI.shared.helpArticleList(query: query, language: SupportStrings.language)
    }

    /// One help article with its markdown body, in the chat's language. Throws an
    /// `AppReferSupportError` whose `isNotFound` is true (HTTP 404) when the article doesn't
    /// exist or isn't published.
    public func article(slug: String) async throws -> AppReferHelpArticleDetail {
        try await SupportAPI.shared.helpArticle(slug: slug, language: SupportStrings.language)
    }

    /// What Support can do for this app: whether reply notifications work on iOS
    /// (`pushReady`), whether customers can answer by email (`emailReplies`) and how many
    /// help articles are published. Register for push only when `pushReady` is true.
    /// Cached as long as the server allows (5 minutes once everything is verified, else 30 s).
    public func status() async throws -> AppReferSupportStatus {
        try await SupportAPI.shared.supportStatus()
    }

    private func present(_ view: AppReferSupportView) {
        if let presented, presented.presentingViewController != nil {
            presented.dismiss(animated: false)
        }
        guard let top = Self.topViewController() else { return }
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presented = host
        top.present(host, animated: true)
    }

    /// Pass the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// The token is registered for `effectivePushEnvironment`.
    public func registerDeviceToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let sandbox = effectivePushEnvironment == .sandbox
        let epoch = SupportAPI.shared.actionGeneration
        Task { try? await SupportAPI.shared.registerPushToken(hex, sandbox: sandbox, generation: epoch) }
    }

    /// True (and opens the conversation) when a notification is a support reply.
    @discardableResult
    public func handleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = userInfo["apprefer"] as? [String: Any], payload["type"] as? String == "support_reply" else { return false }
        open(conversationId: payload["conversationId"] as? String)
        return true
    }

    /// Unread team replies across the customer's conversations (for a badge).
    public func unreadCount() async -> Int {
        ((try? await SupportAPI.shared.conversations()) ?? []).reduce(0) { $0 + $1.unread }
    }

    var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Help"
    }

    var resolvedTitle: String { title ?? SupportStrings.text("support.home.title", ["app": appName]) }

    var resolvedIcon: UIImage? {
        if let appIcon { return appIcon }
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let name = (primary["CFBundleIconFiles"] as? [String])?.last else { return nil }
        return UIImage(named: name)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

/// A quick-help tile on the home screen. Tapping it starts a message on that
/// topic, or runs `action` instead (e.g. your own restore-purchases flow).
public struct AppReferSupportTopic: Identifiable {
    public let id: String
    /// The tile's title; also the new conversation's subject.
    public var title: String {
        get { customTitle ?? SupportStrings.text("support.topic.\(builtIn ?? "").title") }
        set { customTitle = newValue }
    }
    public var subtitle: String {
        get { customSubtitle ?? SupportStrings.text("support.topic.\(builtIn ?? "").subtitle") }
        set { customSubtitle = newValue }
    }
    /// An SF Symbol name.
    public var systemImage: String
    public var tint: Color
    /// The hint in the message field once the tile is picked.
    public var prompt: String {
        get { customPrompt ?? SupportStrings.text("support.topic.\(builtIn ?? "").prompt") }
        set { customPrompt = newValue }
    }
    public var action: (@MainActor () -> Void)?

    /// The built-in tiles read their text in the chat's language when shown.
    private var builtIn: String?
    private var customTitle: String?
    private var customSubtitle: String?
    private var customPrompt: String?

    public init(title: String, subtitle: String, systemImage: String, tint: Color, prompt: String, action: (@MainActor () -> Void)? = nil) {
        self.id = title
        self.customTitle = title
        self.customSubtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.customPrompt = prompt
        self.action = action
    }

    private init(builtIn: String, systemImage: String, tint: Color) {
        self.id = builtIn
        self.builtIn = builtIn
        self.systemImage = systemImage
        self.tint = tint
    }

    public static let billing = AppReferSupportTopic(builtIn: "billing", systemImage: "creditcard.fill", tint: Color(red: 0.43, green: 0.29, blue: 1))
    public static let restore = AppReferSupportTopic(builtIn: "restore", systemImage: "arrow.clockwise", tint: Color(red: 0.18, green: 0.56, blue: 0.98))
    public static let bug = AppReferSupportTopic(builtIn: "bug", systemImage: "ladybug.fill", tint: Color(red: 0.94, green: 0.27, blue: 0.33))
    public static let idea = AppReferSupportTopic(builtIn: "idea", systemImage: "lightbulb.fill", tint: Color(red: 0.12, green: 0.72, blue: 0.4))
    public static var defaults: [AppReferSupportTopic] { [.billing, .restore, .bug, .idea] }
}

extension AppRefer {
    /// The in-app help chat. `AppRefer.support.open()`.
    @MainActor public static var support: AppReferSupport { .shared }
}
#endif
