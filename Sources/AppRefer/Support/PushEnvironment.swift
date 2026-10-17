import Foundation

/// The APNs environment this build's device tokens belong to.
public enum AppReferPushEnvironment: String, Sendable, CaseIterable {
    /// api.push.apple.com: App Store, TestFlight, Ad Hoc and Enterprise builds.
    case production
    /// api.sandbox.push.apple.com: development-signed builds and the Simulator.
    case sandbox
}

/// Reads the APNs environment from how the app is signed, not from DEBUG: a Release build
/// signed with a development profile still gets sandbox tokens, and a Debug build signed for
/// distribution gets production ones.
///
/// - Simulator: sandbox (Simulator push uses the sandbox).
/// - `embedded.mobileprovision` (`embedded.provisionprofile` on macOS) present: its
///   `Entitlements` › `aps-environment` decides: `development` = sandbox, `production` =
///   production.
/// - No profile (App Store and TestFlight builds have none), an unreadable, oversized or
///   malformed one, or no `aps-environment` in it: production.
///
/// Only public Foundation APIs: the profile's CMS envelope is not verified (the OS already did
/// that at install); the embedded XML property list is located by its markers and parsed with
/// `PropertyListSerialization`.
enum PushEnvironmentDetector {
    /// Profiles are a few KB to a few hundred KB; anything larger is not read.
    static let maxProfileBytes = 2 * 1024 * 1024

    static func environment(profile: Data?, isSimulator: Bool) -> AppReferPushEnvironment {
        if isSimulator { return .sandbox }
        guard let profile, let aps = apsEnvironment(inProfile: profile) else { return .production }
        return aps == "development" ? .sandbox : .production
    }

    /// The `aps-environment` entitlement in a provisioning profile, or nil.
    static func apsEnvironment(inProfile data: Data) -> String? {
        guard !data.isEmpty, data.count <= maxProfileBytes,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex)
        else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        let value = entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]
        guard let aps = value as? String, aps == "development" || aps == "production" else { return nil }
        return aps
    }

    /// The embedded profile's bytes, or nil when there is none or it is too large to be one.
    static func embeddedProfile(bundle: Bundle = .main) -> Data? {
        #if os(macOS)
        let url = bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        #else
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        #endif
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= maxProfileBytes else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// This process's detected environment (read once; the profile can't change while running).
    static let detected: AppReferPushEnvironment = environment(profile: embeddedProfile(), isSimulator: isSimulator)
}

/// The environment Support registers tokens for and checks readiness against: the app's
/// explicit choice (`AppRefer.support.pushEnvironment`), else the detected one.
final class PushEnvironmentSetting: @unchecked Sendable {
    static let shared = PushEnvironmentSetting()
    private let lock = NSLock()
    private var explicit: AppReferPushEnvironment?
    private let detect: () -> AppReferPushEnvironment
    private var detected: AppReferPushEnvironment?

    init(detect: @escaping () -> AppReferPushEnvironment = { PushEnvironmentDetector.detected }) { self.detect = detect }

    var override: AppReferPushEnvironment? {
        get { lock.lock(); defer { lock.unlock() }; return explicit }
        set { lock.lock(); explicit = newValue; lock.unlock() }
    }

    var effective: AppReferPushEnvironment {
        lock.lock(); defer { lock.unlock() }
        if let explicit { return explicit }
        if let detected { return detected }
        let value = detect()
        detected = value
        return value
    }
}
