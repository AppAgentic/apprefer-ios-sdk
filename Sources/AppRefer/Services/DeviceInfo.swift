import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AppReferDeviceInfo {
    static func collect() -> [String: Any] {
        var info: [String: Any] = [
            "platform": "ios",
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
        ]

        // App info from Bundle
        if let bundleInfo = Bundle.main.infoDictionary {
            info["app_version"] = bundleInfo["CFBundleShortVersionString"] as? String ?? ""
            info["app_build"] = bundleInfo["CFBundleVersion"] as? String ?? ""
        }
        info["bundle_id"] = Bundle.main.bundleIdentifier ?? ""

        // Device model via utsname
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        info["model"] = machine

        #if canImport(UIKit)
        info["os_version"] = UIDevice.current.systemVersion
        info["device_name"] = UIDevice.current.name
        #endif

        #if targetEnvironment(simulator)
        info["is_physical_device"] = false
        #else
        info["is_physical_device"] = true
        #endif

        return info
    }
}
