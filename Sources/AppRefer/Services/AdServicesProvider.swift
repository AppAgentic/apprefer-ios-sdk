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
        // Dynamic lookup to avoid hard link to AdServices framework.
        // Uses performSelector to let the ObjC runtime handle ARC ownership
        // correctly, instead of unsafeBitCast which can mismatch ARC conventions.
        guard let adServicesClass = NSClassFromString("AAAttribution") as? NSObject.Type else {
            return nil
        }
        let selector = NSSelectorFromString("attributionTokenWithError:")
        guard adServicesClass.responds(to: selector) else {
            return nil
        }

        // Use the ObjC try/catch-safe path via NSObject
        var error: NSError?
        let result = withUnsafeMutablePointer(to: &error) { errorPtr -> String? in
            // performSelector is not available for class methods with error params,
            // so we use objc_msgSend via the proper Swift overlay.
            let nsClass = adServicesClass as AnyObject
            let methodIMP = class_getClassMethod(adServicesClass, selector)
            guard methodIMP != nil else { return nil }

            // Use @convention(c) with proper autoreleasing semantics
            typealias TokenFunc = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSString?
            let imp = method_getImplementation(methodIMP!)
            let function = unsafeBitCast(imp, to: TokenFunc.self)

            var autoreleasingError: NSError?
            let token = withUnsafeMutablePointer(to: &autoreleasingError) { autoPtr in
                function(
                    nsClass,
                    selector,
                    AutoreleasingUnsafeMutablePointer(autoPtr)
                )
            }

            errorPtr.pointee = autoreleasingError
            return token as String?
        }

        if error != nil {
            return nil
        }

        return result
    }
}
