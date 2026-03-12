import Foundation
#if canImport(AdServices)
import AdServices
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

enum AppReferAdServices {
    /// Returns the AdServices attribution token on iOS 14.3+.
    /// Returns nil on simulators, earlier versions, or if the token is unavailable.
    static func getToken() -> String? {
        #if targetEnvironment(simulator)
        // AdServices throws an uncatchable NSException on simulator
        return nil
        #else
        if #available(iOS 14.3, macOS 11.1, *) {
            return _getAdServicesToken()
        }
        return nil
        #endif
    }

    /// Returns the IDFA if App Tracking Transparency is authorized.
    /// Returns nil if ATT is not authorized, denied, or on simulator.
    static func getIdfa() -> String? {
        #if canImport(AdSupport) && canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else {
                return nil
            }
        }
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        // All-zeros means tracking is effectively disabled
        if idfa == "00000000-0000-0000-0000-000000000000" {
            return nil
        }
        return idfa
        #else
        return nil
        #endif
    }

    #if !targetEnvironment(simulator)
    @available(iOS 14.3, macOS 11.1, *)
    private static func _getAdServicesToken() -> String? {
        #if canImport(AdServices)
        do {
            return try AAAttribution.attributionToken()
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
    #endif
}
