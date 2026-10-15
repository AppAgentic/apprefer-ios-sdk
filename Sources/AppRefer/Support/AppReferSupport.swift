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
    /// The promise under the greeting.
    public var replyTimeText = "Ask us anything. We usually reply in under an hour."

    private weak var presented: UIViewController?

    private init() {}

    /// Who the customer is, so the team can greet them and reply by email.
    public func identify(name: String? = nil, email: String? = nil) {
        Task { await SupportAPI.shared.setIdentity(name: name, email: email) }
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
        Task { try? await SupportAPI.shared.registerPushToken(hex, sandbox: sandbox) }
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

    var resolvedTitle: String {
        if let title { return title }
        let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Help"
        return "\(name) support"
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

extension AppRefer {
    /// The in-app help chat. `AppRefer.support.open()`.
    @MainActor public static var support: AppReferSupport { .shared }
}
#endif
