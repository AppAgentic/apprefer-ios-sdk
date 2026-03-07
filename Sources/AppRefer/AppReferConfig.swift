import Foundation

/// Configuration for the AppRefer SDK.
public struct AppReferConfig: Sendable {
    /// SDK key from the AppRefer dashboard (starts with `pk_`)
    public let apiKey: String

    /// Optional: set RevenueCat user ID at init time
    public let userId: String?

    /// Enable debug logging (default: false)
    public let debug: Bool

    /// Log level: 0=none, 1=errors, 2=warnings, 3=verbose (default: 1)
    public let logLevel: Int

    public init(
        apiKey: String,
        userId: String? = nil,
        debug: Bool = false,
        logLevel: Int = 1
    ) {
        self.apiKey = apiKey
        self.userId = userId
        self.debug = debug
        self.logLevel = logLevel
    }

    /// The AppRefer backend URL.
    internal static let backendURL = "https://apprefer.com"
}
