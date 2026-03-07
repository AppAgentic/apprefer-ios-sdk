import Foundation

/// Configuration for the AppRefer SDK.
public struct AppReferConfig: Sendable {
    /// Your tracking domain (e.g., "https://trk.yourdomain.com")
    public let backendURL: String

    /// App identifier matching your AppRefer dashboard
    public let appId: String

    /// Optional: set RevenueCat user ID at init time
    public let userId: String?

    /// Enable debug logging (default: false)
    public let debug: Bool

    /// Log level: 0=none, 1=errors, 2=warnings, 3=verbose (default: 1)
    public let logLevel: Int

    public init(
        backendURL: String,
        appId: String,
        userId: String? = nil,
        debug: Bool = false,
        logLevel: Int = 1
    ) {
        self.backendURL = backendURL
        self.appId = appId
        self.userId = userId
        self.debug = debug
        self.logLevel = logLevel
    }
}
