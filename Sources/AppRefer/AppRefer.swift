import Foundation

/// AppRefer SDK — first-party mobile attribution for iOS.
///
/// Usage:
/// ```swift
/// let attribution = try await AppRefer.configure(
///     backendURL: "https://trk.yourdomain.com",
///     appId: "your-app"
/// )
/// ```
public actor AppRefer {
    private static var shared: AppRefer?

    private let config: AppReferConfig
    private let storage: AppReferStorage
    private let httpClient: AppReferHTTPClient
    private let logger: AppReferLogger

    private init(config: AppReferConfig) {
        self.config = config
        self.logger = AppReferLogger(debug: config.debug, logLevel: config.logLevel)
        self.storage = AppReferStorage()
        self.httpClient = AppReferHTTPClient(
            backendURL: config.backendURL,
            appId: config.appId,
            logger: logger
        )
    }

    // MARK: - Public API

    /// Configure the SDK and resolve attribution.
    ///
    /// On first launch: sends device signals + AdServices token to backend,
    /// resolves attribution, caches locally, returns result.
    /// On subsequent launches: returns cached attribution (no network call).
    @discardableResult
    public static func configure(
        backendURL: String,
        appId: String,
        userId: String? = nil,
        debug: Bool = false,
        logLevel: Int = 1
    ) async throws -> Attribution? {
        let config = AppReferConfig(
            backendURL: backendURL,
            appId: appId,
            userId: userId,
            debug: debug,
            logLevel: logLevel
        )

        let sdk = AppRefer(config: config)
        shared = sdk

        return await sdk._configure()
    }

    /// Track a non-purchase event (signup, tutorial_complete, etc.).
    /// Purchases are tracked via RevenueCat webhooks, NOT here.
    public static func trackEvent(
        _ eventName: String,
        properties: [String: Any]? = nil,
        revenue: Double? = nil,
        currency: String? = nil
    ) async throws {
        guard let sdk = shared else {
            throw AppReferError.notConfigured
        }
        await sdk._trackEvent(eventName, properties: properties, revenue: revenue, currency: currency)
    }

    /// Send hashed user PII for Meta Advanced Matching.
    /// Call once after signup/login. Data is SHA256-hashed before sending.
    public static func setAdvancedMatching(
        email: String? = nil,
        phone: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        dateOfBirth: String? = nil
    ) async throws {
        guard let sdk = shared else {
            throw AppReferError.notConfigured
        }
        await sdk._setAdvancedMatching(
            email: email, phone: phone,
            firstName: firstName, lastName: lastName,
            dateOfBirth: dateOfBirth
        )
    }

    /// Set RevenueCat app_user_id so webhook events can be linked
    /// to this device's attribution.
    public static func setUserId(_ userId: String) async throws {
        guard let sdk = shared else {
            throw AppReferError.notConfigured
        }
        await sdk._setUserId(userId)
    }

    /// Get cached attribution result (no network call).
    public static func getAttribution() async -> Attribution? {
        return shared?.storage.getCachedAttribution()
    }

    /// Get the AppRefer device ID (for setting as RC subscriber attribute).
    public static func getDeviceId() async -> String? {
        return shared?.storage.getDeviceId()
    }

    // MARK: - Internal Implementation

    private func _configure() async -> Attribution? {
        logger.info("AppRefer SDK initialized with appId: \(config.appId)")

        // Set user ID if provided at init time
        if let userId = config.userId {
            storage.setUserId(userId)
        }

        // Record first run date
        _ = storage.getFirstRunDate()

        // Check kill switch from local cache
        if !storage.isSdkEnabled() {
            logger.info("SDK disabled by kill switch")
            return storage.getCachedAttribution()
        }

        // If match already attempted, return cached attribution
        if storage.isMatchRequestAttempted() {
            logger.info("Skipping match request: existing install detected.")
            return storage.getCachedAttribution()
        }

        // First run — resolve attribution
        return await resolveAttribution()
    }

    private func resolveAttribution() async -> Attribution? {
        let deviceId = storage.getDeviceId()
        let deviceInfo = AppReferDeviceInfo.collect()

        // Get AdServices token (iOS only — always iOS here)
        let asaToken = AppReferAdServices.getToken()

        var body: [String: Any] = [
            "app_id": config.appId,
            "device_id": deviceId,
            "device_info": deviceInfo,
            "sdk_version": "0.1.0",
            "is_debug": config.debug,
        ]

        if let asaToken = asaToken {
            body["asa_token"] = asaToken
        }
        if let userId = storage.getUserId() {
            body["customer_user_id"] = userId
        }

        logger.info("Sending configure request...")
        guard let response = await httpClient.post("/api/track/configure", body: body) else {
            logger.error("Configure request failed")
            storage.setMatchRequestAttempted(true)
            return nil
        }

        // Update kill switch from server
        let sdkEnabled = response["sdk_enabled"] as? Bool ?? true
        storage.setSdkEnabled(sdkEnabled)
        if !sdkEnabled {
            logger.info("SDK disabled by server")
            storage.setMatchRequestAttempted(true)
            return nil
        }

        // Parse attribution
        var attribution: Attribution?
        if let attrDict = response["attribution"] as? [String: Any] {
            if let attrData = try? JSONSerialization.data(withJSONObject: attrDict),
               let parsed = try? JSONDecoder().decode(Attribution.self, from: attrData) {
                attribution = parsed
                if let jsonString = String(data: attrData, encoding: .utf8) {
                    storage.setAttributionCache(jsonString)
                }
                logger.info("Attribution resolved: \(parsed.network) via \(parsed.matchType)")
            }
        } else {
            logger.info("No attribution (organic install)")
        }

        // Mark dedup flags
        storage.setMatchRequestAttempted(true)
        storage.setInstallEventSent(true)
        storage.setLastConfigFetch(ISO8601DateFormatter().string(from: Date()))

        return attribution
    }

    private func _trackEvent(
        _ eventName: String,
        properties: [String: Any]?,
        revenue: Double?,
        currency: String?
    ) async {
        guard storage.isSdkEnabled() else { return }

        let deviceId = storage.getDeviceId()
        var body: [String: Any] = [
            "app_id": config.appId,
            "device_id": deviceId,
            "event_name": eventName,
        ]

        if let properties = properties {
            body["properties"] = properties
        }
        if let revenue = revenue {
            body["revenue"] = revenue
        }
        if let currency = currency {
            body["currency"] = currency
        }

        logger.info("Tracking event: \(eventName)")
        _ = await httpClient.post("/api/track/event", body: body)
    }

    private func _setAdvancedMatching(
        email: String?,
        phone: String?,
        firstName: String?,
        lastName: String?,
        dateOfBirth: String?
    ) async {
        guard storage.isSdkEnabled() else { return }

        var hashedData: [String: String] = [:]
        if let email = email { hashedData["em"] = AppReferHashing.hashEmail(email) }
        if let phone = phone { hashedData["ph"] = AppReferHashing.hashPhone(phone) }
        if let firstName = firstName { hashedData["fn"] = AppReferHashing.hashName(firstName) }
        if let lastName = lastName { hashedData["ln"] = AppReferHashing.hashName(lastName) }
        if let dateOfBirth = dateOfBirth { hashedData["db"] = AppReferHashing.hashDateOfBirth(dateOfBirth) }

        if hashedData.isEmpty { return }

        let deviceId = storage.getDeviceId()
        let body: [String: Any] = [
            "app_id": config.appId,
            "device_id": deviceId,
            "event_name": "_advanced_matching",
            "advanced_matching": hashedData,
        ]

        logger.info("Sending advanced matching data")
        _ = await httpClient.post("/api/track/event", body: body)
    }

    private func _setUserId(_ userId: String) async {
        storage.setUserId(userId)
        logger.info("User ID set: \(userId)")
    }
}

// MARK: - Errors

public enum AppReferError: Error, LocalizedError {
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AppRefer.configure() must be called first"
        }
    }
}
