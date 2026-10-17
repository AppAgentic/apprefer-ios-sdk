import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// AppRefer lifecycle engagement on the device: registers this install for lifecycle
/// notifications (only when your app calls `start()`), keeps its push token, time zone,
/// language and permission current, records the person's own choices per purpose, binds the
/// install to a signed-in account only with an assertion from your backend, and handles
/// AppRefer's notifications (validation, buttons, snooze, deferred navigation, receipts).
///
/// It is separate from Support: Support's session, push token and `support_reply`
/// notifications never enroll anyone, and Support's handlers ignore engagement notifications.
/// Nothing here asks for notification permission or tracking consent.
///
/// ```swift
/// await AppRefer.configure(apiKey: "pk_live_…")
/// await AppRefer.engagement.start(options: .init(appGroup: "group.com.example.app", notificationServiceExtension: true))
/// // didRegisterForRemoteNotificationsWithDeviceToken:
/// await AppRefer.engagement.setDeviceToken(deviceToken)
/// // After sign-in, with an assertion your backend got from AppRefer for this install:
/// try await AppRefer.engagement.identify(assertion: assertion)
/// ```
public final class AppReferEngagement: @unchecked Sendable {
    public static let shared = AppReferEngagement()

    let client: EngagementClient
    #if os(iOS)
    @MainActor private(set) lazy var notifications = EngagementNotifications(
        snapshot: client.snapshot,
        receipts: { [client] kind, payload, actionId, at in await client.queueReceipt(kind: kind, payload: payload, actionId: actionId, at: at) },
        system: LiveEngagementNotificationSystem())
    #endif

    init(client: EngagementClient = .shared) {
        self.client = client
        #if os(iOS)
        // Every identity change the client sees (sign-in, logout, reset, deletion, a key switch,
        // an epoch moved by the backend, also one learned at a cold start) removes AppRefer's
        // local snoozes and held navigation for the old identity.
        client.identityObserver.set { [weak self] in
            Task { @MainActor in await self?.notifications.identityInvalidated() }
        }
        #endif
    }

    // MARK: Setup

    /// Registers this install for lifecycle engagement (once; the credential is kept in the
    /// Keychain) and verifies it. Uses the key passed to `AppRefer.configure` unless you pass
    /// one. Offline or before first unlock it returns `.pending` and retries when the app
    /// becomes active; `.disabled` when engagement is off for the app on the server. Also
    /// registers AppRefer's notification categories next to your own. Never prompts.
    @discardableResult
    public func start(apiKey: String? = nil, options: AppReferEngagementOptions = .init()) async -> AppReferEngagementStatus {
        guard let key = apiKey ?? AppRefer.currentApiKey() else { return .notStarted }
        #if os(iOS)
        await registerNotificationCategories()
        #endif
        return await client.start(apiKey: key, explicit: apiKey != nil, options: options)
    }

    public func status() async -> AppReferEngagementStatus { await client.status }

    /// The APNs device token from `didRegisterForRemoteNotificationsWithDeviceToken`. Kept in
    /// memory and sent for the APNs environment the app is signed for (the same rule and
    /// override as `AppRefer.support.pushEnvironment`).
    public func setDeviceToken(_ deviceToken: Data) async {
        await client.setPushToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    /// Re-reads the system notification permission (call after your own permission prompt)
    /// and the device's time zone and language, and tells AppRefer if anything changed.
    public func refreshDeviceState() async { await client.refreshDeviceState() }

    /// The system permission as AppRefer reads it. Never prompts.
    public func notificationPermission() async -> AppReferNotificationPermission { await EngagementPermission.current() }

    // MARK: Preferences

    /// The person's choices for the account (or anonymous install) using the app now.
    public func preferences() async throws -> AppReferEngagementPreferences { try await client.preferences() }

    /// Saves the person's own choices (only the ones you pass). Throws `.identityChanged` if
    /// the account changed meanwhile, so a choice is never saved for someone else.
    @discardableResult
    public func setPreferences(marketing: Bool? = nil, reminders: Bool? = nil, service: Bool? = nil) async throws -> AppReferEngagementPreferences {
        var choices: [String: Bool] = [:]
        if let marketing { choices["marketing"] = marketing }
        if let reminders { choices["reminders"] = reminders }
        if let service { choices["service"] = service }
        return try await client.setPreferences(choices)
    }

    // MARK: Identity

    /// Binds this install to the signed-in account. `assertion` comes from your backend
    /// (`POST /api/v1/apps/{appId}/engagement/assertions` with an `engagement:identity` key,
    /// for this install's id from `status()`); a user id alone is never accepted. Choices
    /// made before sign-in don't carry over to the account.
    public func identify(assertion: String) async throws {
        #if os(iOS)
        await MainActor.run { notifications.resetForAccountChange() }
        #endif
        try await client.identify(assertion: assertion)
    }

    /// Sign-out: AppRefer stops messages planned for the account on this install. Also done
    /// by `AppRefer.reset()`. Saved and sent later if offline.
    public func logout() async {
        #if os(iOS)
        await MainActor.run { notifications.resetForAccountChange() }
        #endif
        await client.logout()
    }

    /// Forgets this install's engagement registration here and on the server.
    public func deleteInstall() async {
        #if os(iOS)
        await MainActor.run { notifications.resetForAccountChange() }
        #endif
        await client.deleteInstall()
    }

    #if os(iOS)
    // MARK: Notifications (your UNUserNotificationCenterDelegate forwards to these)

    /// Opened notifications, buttons, snoozes, dismissals and foreground receipts, each
    /// delivered once. Navigation events (`isNavigation`) wait for `setNavigationReady(true)`.
    @MainActor public var onNotificationEvent: ((AppReferEngagementNotificationEvent) -> Void)? {
        get { notifications.handler }
        set { notifications.handler = newValue }
    }

    /// Call with true once your app knows who is signed in and can show screens (and false
    /// while it can't, e.g. during sign-out). Navigation from a tap is held until then.
    @MainActor public func setNavigationReady(_ ready: Bool) { notifications.setNavigationReady(ready) }

    /// Adds AppRefer's button categories (`apprefer.eng.*`) to your app's own, labelled in
    /// the app's language. `start()` does this; call again after replacing all categories.
    public func registerNotificationCategories() async {
        let categories = EngagementCategory.all { SupportStrings.text("engagement.action.\($0.rawValue)") }
        await LiveEngagementNotificationSystem().registerCategories(categories)
    }

    /// From `userNotificationCenter(_:didReceive:)`: true when the response was AppRefer's
    /// (then call the completion handler after this returns). False for anything else,
    /// including Support replies: handle those as before.
    @MainActor public func handle(_ response: UNNotificationResponse) async -> Bool {
        let content = response.notification.request.content
        return await notifications.handleResponse(userInfo: content.userInfo, actionIdentifier: response.actionIdentifier,
                                                  categoryIdentifier: content.categoryIdentifier)
    }

    /// From `userNotificationCenter(_:willPresent:)`: nil when it isn't AppRefer's; otherwise
    /// the options to present it with (none for an expired or other-account notification).
    @MainActor public func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        guard let show = notifications.presentation(notification.request.content.userInfo) else { return nil }
        return show ? [.banner, .list, .sound] : []
    }
    #endif
}

extension AppRefer {
    /// Lifecycle engagement: `AppRefer.engagement.start()`.
    public static var engagement: AppReferEngagement { .shared }

    /// The engagement header for a queued product event, when its stamp is still current.
    /// The engagement headers for a queued product event, when its stamp is still current: the
    /// install credential and the account epoch the event was queued under.
    static func engagementHeaders(stamp: String?) -> [String: String]? {
        guard let stamp, let snap = EngagementClient.shared.snapshot.get(), let epoch = snap.accountEpoch, snap.stamp == stamp else { return nil }
        return ["X-AppRefer-Install": snap.header, "X-AppRefer-Install-Epoch": String(epoch)]
    }

    /// The stamp a new product event carries: only for events the app chose, sent with the
    /// same SDK key as engagement.
    static func engagementStamp(eventName: String, apiKey: String) -> String? {
        guard !eventName.hasPrefix("_"), let snap = EngagementClient.shared.snapshot.get(), snap.accountEpoch != nil,
              snap.slot == EngagementClient.slot(for: apiKey), snap.trackedEvents?.contains(eventName) ?? true else { return nil }
        return snap.stamp
    }
}
