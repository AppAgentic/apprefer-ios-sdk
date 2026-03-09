import Foundation
#if canImport(AdServices)
import AdServices
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
