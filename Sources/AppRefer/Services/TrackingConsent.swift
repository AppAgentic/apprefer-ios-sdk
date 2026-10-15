import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

/// Whether this install's data may be used for cross-company tracking (ad-network
/// matching and conversion forwarding). Read from App Tracking Transparency; the SDK
/// never shows the prompt itself.
public enum AppReferTrackingConsent: String, Sendable {
    /// ATT authorized.
    case granted
    /// ATT denied or restricted.
    case denied
    /// ATT not determined yet.
    case undetermined

    /// The host for a request whose data may be used for tracking only when consent is
    /// granted. `trk.apprefer.com` is the one domain apps declare in
    /// `NSPrivacyTrackingDomains`; everything else goes to `apprefer.com`. Never both.
    var baseURL: String {
        self == .granted ? AppReferConfig.trackingURL : AppReferConfig.backendURL
    }
}

/// Reads the current ATT status. Abstracted for tests.
protocol TrackingStatusProvider: Sendable {
    func current() -> AppReferTrackingConsent
}

struct LiveTrackingStatusProvider: TrackingStatusProvider {
    func current() -> AppReferTrackingConsent {
        #if canImport(AppTrackingTransparency)
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .denied
        }
        #else
        return .denied
        #endif
    }
}
