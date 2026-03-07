import Foundation

enum AppReferAdServices {
    /// Returns the AdServices attribution token on iOS 14.3+.
    /// Returns nil on earlier versions or if the token is unavailable.
    static func getToken() -> String? {
        if #available(iOS 14.3, *) {
            return _getAdServicesToken()
        }
        return nil
    }

    @available(iOS 14.3, *)
    private static func _getAdServicesToken() -> String? {
        // Dynamic lookup to avoid hard link to AdServices framework
        guard let adServicesClass = NSClassFromString("AAAttribution") else {
            return nil
        }
        let selector = NSSelectorFromString("attributionTokenWithError:")
        guard adServicesClass.responds(to: selector) else {
            return nil
        }

        // Use NSInvocation-style call via perform
        let method = class_getClassMethod(adServicesClass, selector)
        guard method != nil else { return nil }

        typealias AttributionTokenFunc = @convention(c) (AnyClass, Selector, UnsafeMutablePointer<NSError?>) -> NSString?
        let imp = method_getImplementation(method!)
        let function = unsafeBitCast(imp, to: AttributionTokenFunc.self)

        var error: NSError?
        let token = function(adServicesClass, selector, &error)

        if let error = error {
            _ = error // Silently fail — token unavailable
            return nil
        }

        return token as String?
    }
}
