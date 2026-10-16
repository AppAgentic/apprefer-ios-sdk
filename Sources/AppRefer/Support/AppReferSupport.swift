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
    /// Header title. Defaults to "<App name> support".
    public var title: String?
    /// How fast the team usually answers, completing "We usually reply in …".
    public var replyTime = "under an hour"
    /// First names of the people who answer (e.g. `["Jay"]`), shown on the help home.
    public var teamNames: [String] = []
    /// The quick-help tiles on the home screen. Empty hides them.
    public var topics: [AppReferSupportTopic] = AppReferSupportTopic.defaults
    /// The icon on the home screen. Defaults to the app icon.
    public var appIcon: UIImage?

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
    public func registerDeviceToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
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

    var resolvedTitle: String { title ?? "\(appName) support" }

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
    public var title: String
    public var subtitle: String
    /// An SF Symbol name.
    public var systemImage: String
    public var tint: Color
    /// The hint in the message field once the tile is picked.
    public var prompt: String
    public var action: (@MainActor () -> Void)?

    public init(title: String, subtitle: String, systemImage: String, tint: Color, prompt: String, action: (@MainActor () -> Void)? = nil) {
        self.id = title
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.prompt = prompt
        self.action = action
    }

    public static let billing = AppReferSupportTopic(title: "Billing & refunds", subtitle: "Charges, plans, receipts", systemImage: "creditcard.fill", tint: Color(red: 0.43, green: 0.29, blue: 1), prompt: "What happened with the charge?")
    public static let restore = AppReferSupportTopic(title: "Restore purchase", subtitle: "Get your plan back", systemImage: "arrow.clockwise", tint: Color(red: 0.18, green: 0.56, blue: 0.98), prompt: "Which plan did you buy, and on which account?")
    public static let bug = AppReferSupportTopic(title: "Report a bug", subtitle: "Screenshots welcome", systemImage: "ladybug.fill", tint: Color(red: 0.94, green: 0.27, blue: 0.33), prompt: "What went wrong? A screenshot helps.")
    public static let idea = AppReferSupportTopic(title: "Suggest an idea", subtitle: "We read every one", systemImage: "lightbulb.fill", tint: Color(red: 0.12, green: 0.72, blue: 0.4), prompt: "What would make the app better for you?")
    public static var defaults: [AppReferSupportTopic] { [.billing, .restore, .bug, .idea] }
}

extension AppRefer {
    /// The in-app help chat. `AppRefer.support.open()`.
    @MainActor public static var support: AppReferSupport { .shared }
}
#endif
