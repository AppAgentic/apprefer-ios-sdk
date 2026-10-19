import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Reads the system notification permission. Never asks for it.
enum EngagementPermission {
    static func current() async -> AppReferNotificationPermission {
        #if os(iOS) || os(macOS)
        // The notification center needs a real app bundle (not a command-line test runner).
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return .unknown }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .granted
        case .provisional: return .provisional
        case .denied: return .denied
        case .notDetermined: return .unknown
        #if os(iOS)
        case .ephemeral: return .provisional
        #endif
        @unknown default: return .unknown
        }
        #else
        return .unknown
        #endif
    }
}

/// What the notification layer needs from the system, so it can be tested without one.
protocol EngagementNotificationSystem: Sendable {
    func scheduleSnooze(identifier: String, title: String, subtitle: String?, body: String, userInfo: [String: Any],
                        category: String?, thread: String?, after seconds: TimeInterval) async -> Bool
    func registerCategories(_ categories: [EngagementCategory]) async
    /// Removes AppRefer's own local snoozes, pending and delivered: `identifiers` when given,
    /// otherwise every request whose identifier starts with `snoozePrefix`. The app's and
    /// Support's notifications are never touched.
    func removeSnoozes(identifiers: [String]?) async
}

/// Identifier prefix of the local notifications AppRefer schedules for a snooze.
let snoozePrefix = "apprefer.eng.snooze."

/// One iOS category: `apprefer.eng.<kind>[.<kind>]`, buttons `apprefer.action.<index>`.
struct EngagementCategory: Equatable, Sendable {
    let identifier: String
    let actions: [(id: String, title: String, opensApp: Bool)]
    static func == (a: Self, b: Self) -> Bool {
        a.identifier == b.identifier && a.actions.map(\.id) == b.actions.map(\.id) && a.actions.map(\.title) == b.actions.map(\.title)
    }

    /// Every ordered combination of one or two different kinds: 4 + 12 = 16 categories.
    static func all(label: (AppReferEngagementPayload.ActionKind) -> String) -> [EngagementCategory] {
        let kinds = AppReferEngagementPayload.ActionKind.allCases
        var combos: [[AppReferEngagementPayload.ActionKind]] = kinds.map { [$0] }
        for a in kinds { for b in kinds where b != a { combos.append([a, b]) } }
        return combos.map { combo in
            EngagementCategory(
                identifier: "apprefer.eng." + combo.map(\.rawValue).joined(separator: "."),
                actions: combo.enumerated().map { (id: "apprefer.action.\($0.offset)", title: label($0.element), opensApp: $0.element != .snooze) })
        }
    }
}

/// Handles AppRefer lifecycle notifications on the device: validates each one against the
/// current install and account, turns taps and buttons into events delivered exactly once,
/// re-shows snoozed ones, and holds navigation until the host says it is ready.
@MainActor
final class EngagementNotifications {
    private let snapshot: EngagementSnapshotBox
    private let receipts: @Sendable (String, AppReferEngagementPayload, String?, Date) async -> Void
    private let system: EngagementNotificationSystem
    private let defaults: UserDefaults
    private let now: () -> Date

    var handler: ((AppReferEngagementNotificationEvent) -> Void)? { didSet { deliverPending() } }
    private(set) var navigationReady = false
    private var pending: [(event: AppReferEngagementNotificationEvent, payload: AppReferEngagementPayload)] = []

    init(snapshot: EngagementSnapshotBox,
         receipts: @escaping @Sendable (String, AppReferEngagementPayload, String?, Date) async -> Void,
         system: EngagementNotificationSystem,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = { Date() }) {
        self.snapshot = snapshot; self.receipts = receipts; self.system = system; self.defaults = defaults; self.now = now
    }

    func setNavigationReady(_ ready: Bool) {
        navigationReady = ready
        deliverPending()
    }

    /// Advances on every identity change; a snooze whose scheduling straddles one is removed.
    private(set) var invalidations = 0

    /// Account changed or reset: nothing queued for the previous identity is delivered, and its
    /// local snoozes (pending or already shown) are removed so they can't reappear for the next.
    func resetForAccountChange() {
        invalidations += 1
        pending.removeAll()
        let system = self.system
        Task { await system.removeSnoozes(identifiers: nil) }
    }

    /// Awaitable form for callers that need the removal done (tests, sign-out flows).
    func identityInvalidated() async {
        invalidations += 1
        pending.removeAll()
        await system.removeSnoozes(identifiers: nil)
    }

    var pendingCount: Int { pending.count }

    // MARK: Validation

    enum Check: Equatable { case notEngagement, ignored(String), valid(AppReferEngagementPayload) }

    /// Parses and checks a notification against the current install, account and clock.
    func check(_ userInfo: [AnyHashable: Any]) -> Check {
        switch AppReferEngagementPayload.parse(userInfo: userInfo) {
        case .notEngagement: return .notEngagement
        case .invalid(let reason): return .ignored(reason)
        case .valid(let payload):
            guard let current = snapshot.get() else { return .ignored("not_started") }
            guard current.installId == payload.installId else { return .ignored("other_install") }
            guard let epoch = current.accountEpoch, epoch == payload.accountEpoch else { return .ignored("other_account") }
            guard !payload.isExpired(at: now()) else { return .ignored("expired") }
            return .valid(payload)
        }
    }

    /// Buttons shown on this copy: a re-shown (snoozed) copy has no snooze button.
    static func shownActions(_ payload: AppReferEngagementPayload, snoozed: Bool) -> [AppReferEngagementPayload.Action] {
        snoozed ? payload.actions.filter { $0.kind != .snooze } : payload.actions
    }
    static func category(for actions: [AppReferEngagementPayload.Action]) -> String? {
        actions.isEmpty ? nil : "apprefer.eng." + actions.map(\.kind.rawValue).joined(separator: ".")
    }

    // MARK: Foreground presentation

    /// nil: not AppRefer's. Otherwise whether to show it (banner, list, sound) while the app
    /// is open: an invalid, expired or other-account notification is not shown.
    func presentation(_ userInfo: [AnyHashable: Any]) -> Bool? {
        switch check(userInfo) {
        case .notEngagement: return nil
        case .ignored: return false
        case .valid(let payload):
            claim(.received, payload, action: nil)
            return true
        }
    }

    // MARK: Responses

    static let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
    static let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"

    /// True when the response belongs to AppRefer (even if it is ignored as invalid).
    func handleResponse(userInfo: [AnyHashable: Any], actionIdentifier: String, categoryIdentifier: String) async -> Bool {
        let result = check(userInfo)
        guard case .valid(let payload) = result else { return result != .notEngagement }
        let snoozed = userInfo["apprefer_snoozed"] as? Bool == true
        let shown = Self.shownActions(payload, snoozed: snoozed)
        switch actionIdentifier {
        case Self.defaultAction:
            claim(.opened, payload, action: nil)
        case Self.dismissAction:
            claim(.dismissed, payload, action: nil)
        default:
            // Only the buttons of the category this payload asked for, by position.
            guard actionIdentifier.hasPrefix("apprefer.action."), let index = Int(actionIdentifier.dropFirst("apprefer.action.".count)),
                  categoryIdentifier == Self.category(for: shown), shown.indices.contains(index) else { return true }
            let action = shown[index]
            if action.kind == .snooze {
                guard claim(.snoozed, payload, action: action) else { return true }
                await snooze(payload, userInfo: userInfo, minutes: action.snoozeMinutes ?? 60)
            } else {
                claim(.action, payload, action: action)
            }
        }
        return true
    }

    private func snooze(_ payload: AppReferEngagementPayload, userInfo: [AnyHashable: Any], minutes: Int) async {
        let delay = min(TimeInterval(minutes * 60), payload.expiresAt.timeIntervalSince(now()) - 60)
        guard delay >= 60 else { return } // would only reappear expired
        var info: [String: Any] = [:]
        for (k, v) in userInfo { if let key = k as? String { info[key] = v } }
        info["apprefer_snoozed"] = true
        let identifier = snoozePrefix + EngagementClient.slot(for: payload.messageId)
        // Fence: the identity this snooze is for. If it changes while the system call runs (the
        // removal may have run before the add landed), the late request is removed afterwards.
        let fence = invalidations
        guard stillCurrent(payload) else { return }
        _ = await system.scheduleSnooze(
            identifier: identifier,
            title: payload.title, subtitle: payload.subtitle, body: payload.body, userInfo: info,
            category: Self.category(for: Self.shownActions(payload, snoozed: true)), thread: payload.collapseKey, after: delay)
        if fence != invalidations || !stillCurrent(payload) {
            await system.removeSnoozes(identifiers: [identifier])
        }
    }

    /// The payload still matches the current install and account (nil snapshot: not known, e.g.
    /// offline; the identity observer covers real changes).
    private func stillCurrent(_ payload: AppReferEngagementPayload) -> Bool {
        guard let current = snapshot.get() else { return true }
        return current.installId == payload.installId && current.accountEpoch == payload.accountEpoch
    }

    // MARK: Exactly-once delivery

    private static let handledKey = "apprefer_engagement_handled"

    /// Records the event once per message (and button), queues its receipt and delivers it.
    /// Returns false for a repeat.
    @discardableResult
    private func claim(_ kind: AppReferEngagementNotificationEvent.Kind, _ payload: AppReferEngagementPayload, action: AppReferEngagementPayload.Action?) -> Bool {
        let key = "\(kind.rawValue):\(payload.messageId)" + (kind == .action ? ":\(action?.id ?? "")" : "")
        var handled = (defaults.dictionary(forKey: Self.handledKey) as? [String: Date]) ?? [:]
        guard handled[key] == nil else { return false }
        handled[key] = now()
        // Bounded: eight days (past every message's expiry and receipt window), newest 300.
        let fresh = handled.filter { now().timeIntervalSince($0.value) < 8 * 86_400 }.sorted { $0.value > $1.value }.prefix(300)
        defaults.set(Dictionary(uniqueKeysWithValues: fresh.map { ($0.key, $0.value) }), forKey: Self.handledKey)

        let receiptKind: String
        switch kind {
        case .received: receiptKind = "received"
        case .opened: receiptKind = "opened"
        case .action: receiptKind = "action"
        case .snoozed: receiptKind = "snooze"
        case .dismissed: receiptKind = "dismissed"
        }
        let at = now()
        let receipts = self.receipts
        Task { await receipts(receiptKind, payload, action?.id, at) }

        let destination: String? = kind == .opened ? payload.destination : (kind == .action ? (action?.destination ?? payload.destination) : nil)
        let event = AppReferEngagementNotificationEvent(kind: kind, messageId: payload.messageId, purpose: payload.purpose,
                                                        destination: destination, actionId: action?.id, actionKind: action?.kind)
        pending.append((event, payload))
        if pending.count > 20 { pending.removeFirst(pending.count - 20) }
        deliverPending()
        return true
    }

    private func deliverPending() {
        var keep: [(event: AppReferEngagementNotificationEvent, payload: AppReferEngagementPayload)] = []
        let queued = pending
        pending = []
        for item in queued {
            // A Support testimonial invitation belongs to the SDK: it opens even with no app handler.
            let requestId = item.event.isNavigation ? Self.testimonialRequestId(item.event.destination) : nil
            guard handler != nil || requestId != nil else { keep.append(item); continue }
            // Re-checked with the real clock at delivery: a notification that expired while its
            // event waited (navigation not ready, no handler yet) is dropped, never acted on.
            guard !item.payload.isExpired(at: now()) else { continue }
            if item.event.isNavigation {
                guard navigationReady else { keep.append(item); continue }
                // Re-checked at delivery: an account change while it waited drops it.
                guard let current = snapshot.get(), current.installId == item.payload.installId,
                      current.accountEpoch == item.payload.accountEpoch else { continue }
            }
            if let requestId { openTestimonial(requestId) } else { handler?(item.event) }
        }
        pending = keep + pending
    }

    /// The request id when `destination` is a Support testimonial invitation
    /// (`/apprefer/testimonials/<requestId>`): the SDK opens its own capture screen for it and
    /// never passes it to the app's router.
    nonisolated static func testimonialRequestId(_ destination: String?) -> String? {
        let prefix = "/apprefer/testimonials/"
        guard let destination, destination.hasPrefix(prefix) else { return nil }
        let id = String(destination.dropFirst(prefix.count))
        let hex = id.dropFirst(4)
        guard id.hasPrefix("tsr_"), hex.count == 32, hex.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return id
    }

    /// Opens the capture screen for a tapped invitation (tests replace it).
    var openTestimonial: @MainActor (String) -> Void = { requestId in
        #if os(iOS)
        AppReferTestimonials.shared.present(requestId: requestId)
        #else
        _ = requestId
        #endif
    }
}

#if os(iOS)
/// The live system: the app's notification center. Categories are merged with the app's own.
struct LiveEngagementNotificationSystem: EngagementNotificationSystem {
    func scheduleSnooze(identifier: String, title: String, subtitle: String?, body: String, userInfo: [String: Any],
                        category: String?, thread: String?, after seconds: TimeInterval) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.userInfo = userInfo
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        if let thread { content.threadIdentifier = thread }
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
        do { try await UNUserNotificationCenter.current().add(request); return true } catch { return false }
    }

    func removeSnoozes(identifiers: [String]?) async {
        // The notification center needs a real app bundle (not a test runner or tool).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        if let identifiers {
            let ours = identifiers.filter { $0.hasPrefix(snoozePrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            center.removeDeliveredNotifications(withIdentifiers: ours)
            return
        }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(snoozePrefix) }
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(snoozePrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    func registerCategories(_ categories: [EngagementCategory]) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        let ours = categories.map { category in
            UNNotificationCategory(
                identifier: category.identifier,
                actions: category.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: $0.opensApp ? [.foreground] : []) },
                intentIdentifiers: [], options: [.customDismissAction])
        }
        // The app's own categories stay exactly as they are.
        let kept = existing.filter { !$0.identifier.hasPrefix("apprefer.eng.") }
        center.setNotificationCategories(kept.union(ours))
    }
}
#endif
