import Foundation

/// The small, secret-free state the app and its Notification Service Extension share through
/// an App Group the host configures (both targets need the same group entitlement). Optional:
/// without it the extension can't tell which account is signed in, so it still only fetches
/// allowlisted generic artwork, and "received" is reported only for notifications the app sees.
///
/// Holds the install id and account epoch notifications must match (never the install
/// secret, push token or user id), and a bounded list of "received" markers the extension
/// leaves for the app to report.
public struct AppReferNotificationSharedState: Sendable {
    public struct Identity: Equatable, Sendable {
        public let installId: String
        /// nil while an account change is in progress: nothing matches until it settles.
        public let accountEpoch: Int?
        public init(installId: String, accountEpoch: Int?) { self.installId = installId; self.accountEpoch = accountEpoch }
    }

    public struct ReceivedMarker: Codable, Equatable, Sendable {
        public let messageId: String
        public let installId: String
        public let accountEpoch: Int
        public let receiptToken: String
        public let receivedAt: Date
        public init(messageId: String, installId: String, accountEpoch: Int, receiptToken: String, receivedAt: Date) {
            self.messageId = messageId; self.installId = installId; self.accountEpoch = accountEpoch
            self.receiptToken = receiptToken; self.receivedAt = receivedAt
        }
    }

    static let identityKey = "apprefer_engagement_identity"
    static let receivedKey = "apprefer_engagement_received"
    static let maxMarkers = 50

    public let appGroup: String
    public init(appGroup: String) { self.appGroup = appGroup }

    private var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public func identity() -> Identity? {
        guard let dict = defaults?.dictionary(forKey: Self.identityKey), let iid = dict["iid"] as? String else { return nil }
        return Identity(installId: iid, accountEpoch: dict["epoch"] as? Int)
    }

    /// Written by the app whenever its engagement identity changes; nil clears it.
    public func setIdentity(_ identity: Identity?) {
        guard let defaults else { return }
        if let identity {
            var dict: [String: Any] = ["iid": identity.installId]
            if let epoch = identity.accountEpoch { dict["epoch"] = epoch }
            defaults.set(dict, forKey: Self.identityKey)
        } else {
            defaults.removeObject(forKey: Self.identityKey)
        }
    }

    /// True when the payload is for the identity the app last recorded.
    public func matches(_ payload: AppReferEngagementPayload) -> Bool {
        guard let identity = identity(), let epoch = identity.accountEpoch else { return false }
        return identity.installId == payload.installId && epoch == payload.accountEpoch
    }

    public func appendReceived(_ marker: ReceivedMarker) {
        guard let defaults else { return }
        var list = markers(defaults)
        guard !list.contains(where: { $0.messageId == marker.messageId }) else { return }
        list.append(marker)
        list = Array(list.filter { Date().timeIntervalSince($0.receivedAt) < 7 * 86_400 }.suffix(Self.maxMarkers))
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.receivedKey)
    }

    /// Takes (and clears) the extension's received markers.
    public func takeReceived() -> [ReceivedMarker] {
        guard let defaults else { return [] }
        let list = markers(defaults)
        defaults.removeObject(forKey: Self.receivedKey)
        return list
    }

    private func markers(_ defaults: UserDefaults) -> [ReceivedMarker] {
        guard let data = defaults.data(forKey: Self.receivedKey) else { return [] }
        return (try? JSONDecoder().decode([ReceivedMarker].self, from: data)) ?? []
    }
}
