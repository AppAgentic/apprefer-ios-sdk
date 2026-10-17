import Foundation

/// An AppRefer lifecycle notification (wire schema 1), parsed and validated.
///
/// The server sends one `engagement` object in both transports: on APNs as the custom key
/// `apprefer` (`{"type": "engagement", "v": 1, ...}`, next to Support's
/// `{"type": "support_reply"}`), on FCM as the data field `engagement` (a JSON string) with
/// `type = "engagement"`. Anything else is not an engagement notification, so the Support
/// handler and the host's own handlers keep working unchanged.
///
/// Validation is strict and never executes anything: `destination` is an in-app path the
/// host maps to a screen (never a URL the SDK opens), action ids and kinds come from a fixed
/// vocabulary, and an image is only an HTTPS URL to a PNG or JPEG on a plain host name. Whether
/// the message is still valid for *this* install and account (`installId`, `accountEpoch`,
/// `expiresAt`) is checked by the caller against its own state.
public struct AppReferEngagementPayload: Equatable, Sendable {
    public enum Purpose: String, Sendable, CaseIterable { case marketing, reminders, service }

    /// Button kinds. Labels come from the SDK's 35-language table, never from the payload.
    public enum ActionKind: String, Sendable, CaseIterable { case open, view, start, snooze }

    public struct Action: Equatable, Sendable {
        public let id: String
        public let kind: ActionKind
        /// For open/view/start: where it leads (nil = the message's destination).
        public let destination: String?
        /// For snooze: minutes until the notification is shown again (5–1440).
        public let snoozeMinutes: Int?
    }

    public let messageId: String
    public let purpose: Purpose
    public let expiresAt: Date
    public let accountEpoch: Int
    public let installId: String
    public let destination: String?
    public let collapseKey: String?
    public let locale: String?
    public let title: String
    public let subtitle: String?
    public let body: String
    public let imageURL: URL?
    public let actions: [Action]
    /// Proof for this message's device receipts. Not a credential: it only works together
    /// with the install's own credential, for this message, install and account epoch.
    public let receiptToken: String

    public enum Result: Equatable, Sendable {
        /// Not an AppRefer engagement notification: leave it to other handlers.
        case notEngagement
        /// Claimed by AppRefer but malformed or of an unsupported schema: show nothing extra,
        /// navigate nowhere.
        case invalid(String)
        case valid(AppReferEngagementPayload)
    }

    /// The `engagement` dictionary from an APNs `userInfo` (key `apprefer`) or the decoded
    /// JSON of an FCM data field.
    public static func parse(userInfo: [AnyHashable: Any]) -> Result {
        guard let raw = userInfo["apprefer"] as? [String: Any], raw["type"] as? String == "engagement" else { return .notEngagement }
        return parse(object: raw)
    }

    /// FCM data map (`type`, `v`, `engagement` as JSON text).
    public static func parse(data: [String: String]) -> Result {
        guard data["type"] == "engagement" else { return .notEngagement }
        guard let text = data["engagement"], text.utf8.count <= 8192, let json = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return .invalid("malformed") }
        return parse(object: object)
    }

    static let maxTitle = 128
    static let maxBody = 512

    public static func parse(object raw: [String: Any]) -> Result {
        guard raw["type"] as? String == "engagement" else { return .notEngagement }
        guard integer(raw["v"]) == 1 else { return .invalid("unsupported_version") }
        guard let mid = raw["mid"] as? String, matches(mid, #"^[A-Za-z0-9_.:-]{1,400}$"#) else { return .invalid("message_id") }
        guard let purpose = (raw["purpose"] as? String).flatMap(Purpose.init(rawValue:)) else { return .invalid("purpose") }
        guard let exp = number(raw["exp"]), exp > 0 else { return .invalid("expiry") }
        guard let epoch = integer(raw["epoch"]), epoch >= 0 else { return .invalid("epoch") }
        guard let iid = raw["iid"] as? String, matches(iid, #"^ei_[a-z2-7]{26}$"#) else { return .invalid("install") }
        let dest = raw["dest"] is NSNull ? nil : raw["dest"]
        if dest != nil, !isDestination(dest) { return .invalid("destination") }
        let ck = raw["ck"] is NSNull ? nil : raw["ck"]
        if let ck, !((ck as? String).map { matches($0, #"^[a-z0-9_-]{1,32}$"#) } ?? false) { return .invalid("collapse_key") }
        guard let title = raw["title"] as? String, !title.isEmpty, title.count <= maxTitle,
              let body = raw["body"] as? String, !body.isEmpty, body.count <= maxBody else { return .invalid("copy") }
        let subtitle = raw["subtitle"] as? String
        if let subtitle, subtitle.count > maxTitle { return .invalid("copy") }
        var image: URL?
        if let img = raw["img"], !(img is NSNull) {
            guard let text = img as? String, let url = AppReferImagePolicy.validatedURL(text) else { return .invalid("image") }
            image = url
        }
        var actions: [Action] = []
        if let list = raw["actions"], !(list is NSNull) {
            guard let items = list as? [[String: Any]], items.count <= 2 else { return .invalid("actions") }
            for item in items {
                guard let id = item["id"] as? String, matches(id, #"^[a-z0-9][a-z0-9_-]{0,31}$"#),
                      let kind = (item["kind"] as? String).flatMap(ActionKind.init(rawValue:)),
                      !actions.contains(where: { $0.id == id || $0.kind == kind }) else { return .invalid("actions") }
                if kind == .snooze {
                    guard let minutes = integer(item["min"]), (5...1440).contains(minutes), item["dest"] == nil else { return .invalid("actions") }
                    actions.append(Action(id: id, kind: kind, destination: nil, snoozeMinutes: minutes))
                } else {
                    let actionDest = item["dest"] is NSNull ? nil : item["dest"]
                    if actionDest != nil, !isDestination(actionDest) { return .invalid("actions") }
                    actions.append(Action(id: id, kind: kind, destination: actionDest as? String, snoozeMinutes: nil))
                }
            }
        }
        guard let rt = raw["rt"] as? String, matches(rt, #"^er1\.[A-Za-z0-9_-]{43}$"#) else { return .invalid("receipt_token") }
        let locale = (raw["locale"] as? String).flatMap { matches($0, #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$"#) ? $0 : nil }
        return .valid(AppReferEngagementPayload(
            messageId: mid, purpose: purpose, expiresAt: Date(timeIntervalSince1970: exp / 1000), accountEpoch: epoch,
            installId: iid, destination: dest as? String, collapseKey: ck as? String, locale: locale, title: title,
            subtitle: subtitle, body: body, imageURL: image, actions: actions, receiptToken: rt
        ))
    }

    public func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt }

    /// The iOS category registered for these buttons (`apprefer.eng.<kind>[.<kind>]`).
    public var categoryIdentifier: String? {
        actions.isEmpty ? nil : "apprefer.eng." + actions.map(\.kind.rawValue).joined(separator: ".")
    }

    /// An in-app path: one leading "/", no scheme or host, bounded.
    public static func isDestination(_ value: Any?) -> Bool {
        guard let text = value as? String, text.count <= 256, !text.hasPrefix("//") else { return false }
        return matches(text, #"^/[A-Za-z0-9/_\-.~%?=&]*$"#)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    private static func number(_ value: Any?) -> Double? {
        // `is Bool` would also match a bridged NSNumber 0 or 1: check the CF type instead.
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = value as? String { return Double(s) }
        return nil
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let d = number(value), d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }
}

/// Which notification images may be fetched: HTTPS only, a plain DNS host name on the host
/// app's allowlist (never an IP literal, `localhost`, a port or credentials), a path to a
/// `.png`/`.jpg`/`.jpeg` file, no query or fragment, no `.`/`..`/encoded separators.
public enum AppReferImagePolicy {
    public static func validatedURL(_ text: String) -> URL? {
        guard text.count <= 512,
              text.range(of: #"^https://([a-z0-9.-]+)(/[A-Za-z0-9_\-.~%]+)*/[A-Za-z0-9_\-.~%]+\.(png|jpe?g)$"#, options: .regularExpression) != nil,
              let url = URL(string: text), let host = url.host, isHost(host), url.port == nil, url.user == nil, url.query == nil, url.fragment == nil
        else { return nil }
        let path = String(text.dropFirst(8 + host.count))
        guard !path.contains("//") else { return nil }
        for segment in path.split(separator: "/") {
            if segment == "." || segment == ".." || segment.range(of: "%2e|%2f|%5c", options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        }
        return url
    }

    /// A lowercase DNS name with an alphabetic top-level label.
    public static func isHost(_ host: String) -> Bool {
        host.count >= 4 && host.count <= 253 &&
            host.range(of: #"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#, options: .regularExpression) != nil
    }

    /// True when `url` passes `validatedURL` and its host is exactly one of `allowedHosts`.
    public static func isAllowed(_ url: URL, allowedHosts: Set<String>) -> Bool {
        guard let valid = validatedURL(url.absoluteString), let host = valid.host else { return false }
        return allowedHosts.contains(host)
    }
}
