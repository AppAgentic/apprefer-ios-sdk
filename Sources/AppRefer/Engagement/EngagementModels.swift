import Foundation
@_exported import AppReferNotifications

/// Where lifecycle engagement stands on this install.
public enum AppReferEngagementStatus: Equatable, Sendable {
    /// `AppRefer.engagement.start()` hasn't been called in this process.
    case notStarted
    /// Registered with AppRefer and verified.
    case active(installId: String)
    /// Couldn't register or verify yet (offline, Keychain locked before first unlock, server
    /// error). Retried when the app becomes active and on the next `start()`.
    case pending
    /// Lifecycle engagement is off for this app on the server. Checked again after six hours
    /// or on the next launch; nothing is sent meanwhile.
    case disabled
}

/// Options for `AppRefer.engagement.start(options:)`.
public struct AppReferEngagementOptions: Sendable, Equatable {
    /// Product events that carry the install's engagement credential, so lifecycle journeys
    /// can react to them (`AppRefer.trackEvent`). nil = every event your app tracks (names
    /// starting with `_` never carry it). The credential only ever goes to AppRefer.
    public var trackedEvents: Set<String>?
    /// App Group shared with your Notification Service Extension (same value as
    /// `AppReferNotificationServiceConfiguration.appGroup`). Optional.
    public var appGroup: String?
    /// Set when your app ships the Notification Service Extension with
    /// `AppReferNotificationService`, so AppRefer sends images. Without it notifications are text.
    public var notificationServiceExtension: Bool

    public init(trackedEvents: Set<String>? = nil, appGroup: String? = nil, notificationServiceExtension: Bool = false) {
        self.trackedEvents = trackedEvents
        self.appGroup = appGroup
        self.notificationServiceExtension = notificationServiceExtension
    }
}

/// The person's own choices, per purpose. Separate from the system notification permission
/// and from App Tracking Transparency: allowing notifications never turns these on.
public struct AppReferEngagementPreferences: Equatable, Sendable {
    /// Offers and news. Off until the person turns it on in your app.
    public let marketing: Bool
    /// Reminders the person asked for. Off until turned on.
    public let reminders: Bool
    /// Account and billing notices (verified store state). On unless turned off.
    public let service: Bool
}

/// The system notification permission as AppRefer reports it. AppRefer never asks for it.
public enum AppReferNotificationPermission: String, Sendable {
    case granted, provisional, denied, unknown
}

/// Something that happened to an AppRefer lifecycle notification, delivered once.
public struct AppReferEngagementNotificationEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Shown while the app was in the foreground (or reported by the extension).
        case received
        /// The person tapped the notification.
        case opened
        /// The person tapped a button that opens the app.
        case action
        /// The person chose "Remind me later": it is shown again later. Not a completion.
        case snoozed
        /// The person dismissed it.
        case dismissed
    }
    public let kind: Kind
    public let messageId: String
    public let purpose: AppReferEngagementPayload.Purpose
    /// The in-app path to open for `opened` and `action` (your app maps it to a screen;
    /// nil = your default screen). Never a URL to open blindly.
    public let destination: String?
    public let actionId: String?
    public let actionKind: AppReferEngagementPayload.ActionKind?

    /// True for `opened` and `action`: navigate to `destination`. These wait until your app
    /// calls `setNavigationReady(true)` (signed-in state known), and are dropped if the
    /// install's account changed meanwhile.
    public var isNavigation: Bool { kind == .opened || kind == .action }
}

public enum AppReferEngagementError: Error, Equatable, Sendable {
    /// `start()` hasn't registered this install yet.
    case notStarted
    /// Engagement is off for this app on the server.
    case disabled
    /// The install's account changed during the call; read the state again.
    case identityChanged
    /// The account assertion was invalid, expired, already used or for another install.
    case invalidAssertion
    /// Network or storage unavailable; try again later.
    case unavailable
    case server(status: Int, code: String?)
}
