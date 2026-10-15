import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// One AppRefer endpoint. Abstracted so tests can see which host each request used.
protocol AppReferPosting: Sendable {
    func post(_ path: String, body: [String: Any]) async -> [String: Any]?
}

extension AppReferHTTPClient: AppReferPosting {}

/// AppRefer SDK — first-party mobile attribution for iOS.
///
/// Usage:
/// ```swift
/// let attribution = await AppRefer.configure(apiKey: "pk_...")
/// ```
public actor AppRefer {
    // Lock-protected shared instance for thread-safe static access
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _shared: AppRefer?

    private static func getShared() -> AppRefer? {
        lock.lock()
        defer { lock.unlock() }
        return _shared
    }

    private static func setShared(_ sdk: AppRefer) {
        lock.lock()
        defer { lock.unlock() }
        _shared = sdk
    }

    /// SDK key passed to `configure`, used by AppReferBilling.
    static func currentApiKey() -> String? {
        getShared()?.config.apiKey
    }

    private let config: AppReferConfig
    private let storage: AppReferStorage
    private let logger: AppReferLogger
    private let trackingStatus: TrackingStatusProvider
    /// `trk.apprefer.com`, only for ATT-authorized installs.
    private let trackingClient: AppReferPosting
    /// `apprefer.com`, for everything else. Neither falls back to the other.
    private let firstPartyClient: AppReferPosting
    private var consentSyncInFlight = false

    init(
        config: AppReferConfig,
        storage: AppReferStorage = AppReferStorage(),
        trackingStatus: TrackingStatusProvider = LiveTrackingStatusProvider(),
        trackingClient: AppReferPosting? = nil,
        firstPartyClient: AppReferPosting? = nil
    ) {
        self.config = config
        let logger = AppReferLogger(debug: config.debug, logLevel: config.logLevel)
        self.logger = logger
        self.storage = storage
        self.trackingStatus = trackingStatus
        self.trackingClient = trackingClient ?? AppReferHTTPClient(
            primaryURL: AppReferConfig.trackingURL, fallbackURL: nil, apiKey: config.apiKey, logger: logger
        )
        self.firstPartyClient = firstPartyClient ?? AppReferHTTPClient(
            primaryURL: AppReferConfig.backendURL, fallbackURL: nil, apiKey: config.apiKey, logger: logger
        )
    }

    /// Requests whose data may be used for tracking go to the tracking host only when ATT is authorized.
    private func client(for consent: AppReferTrackingConsent) -> AppReferPosting {
        consent == .granted ? trackingClient : firstPartyClient
    }

    // MARK: - Public API

    /// Configure the SDK and resolve attribution.
    ///
    /// On first launch: sends device signals + AdServices token to backend,
    /// resolves attribution, caches locally, returns result.
    /// On subsequent launches: returns cached attribution (no network call).
    @discardableResult
    public static func configure(
        apiKey: String,
        userId: String? = nil,
        debug: Bool = false,
        logLevel: Int = 1
    ) async -> Attribution? {
        let config = AppReferConfig(
            apiKey: apiKey,
            userId: userId,
            debug: debug,
            logLevel: logLevel
        )

        let sdk = AppRefer(config: config)
        setShared(sdk)
        observeActivation()

        return await sdk._configure()
    }

    /// Call right after your own App Tracking Transparency prompt (or any time the
    /// status may have changed). AppRefer re-reads the status, never prompts, and tells
    /// the server: an authorized install is then matched to its ad click once; a denied
    /// one stays first-party and is never forwarded to ad networks. AppRefer also checks
    /// on every `configure` and whenever the app becomes active.
    public static func trackingConsentDidChange() async {
        guard let sdk = getShared() else {
            _log("trackingConsentDidChange called before configure() — ignoring")
            return
        }
        _ = await sdk.syncTrackingConsent()
    }

    /// The tracking consent AppRefer currently applies, from App Tracking Transparency.
    public static func trackingConsent() -> AppReferTrackingConsent {
        LiveTrackingStatusProvider().current()
    }

    private nonisolated(unsafe) static var activationObserver: NSObjectProtocol?

    /// The user can change ATT in Settings at any time; re-check when the app comes back.
    private static func observeActivation() {
        #if canImport(UIKit) && !os(watchOS)
        lock.lock()
        defer { lock.unlock() }
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in
            Task { await AppRefer.trackingConsentDidChange() }
        }
        #endif
    }

    /// Track a non-purchase event (signup, tutorial_complete, etc.).
    /// Purchases are tracked via RevenueCat webhooks, NOT here.
    public static func trackEvent(
        _ eventName: String,
        properties: [String: Any]? = nil,
        revenue: Double? = nil,
        currency: String? = nil
    ) async {
        guard let sdk = getShared() else {
            _log("trackEvent called before configure() — ignoring")
            return
        }
        // Deep-copy properties via JSON round-trip to prevent callers from
        // mutating the dictionary while JSONSerialization walks it inside the actor.
        let safeCopy = properties.flatMap { Self.jsonSafeCopy($0) }
        await sdk._trackEvent(eventName, properties: safeCopy, revenue: revenue, currency: currency)
    }

    /// Deep-copy a [String: Any] dictionary via JSON serialization
    /// to detach from any mutable NSMutableDictionary/NSMutableArray references.
    private static func jsonSafeCopy(_ dict: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return dict }
        return copy
    }

    /// Send hashed user PII for Meta Advanced Matching.
    /// Call once after signup/login. Data is SHA256-hashed before sending.
    public static func setAdvancedMatching(
        email: String? = nil,
        phone: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        dateOfBirth: String? = nil
    ) async {
        guard let sdk = getShared() else {
            _log("setAdvancedMatching called before configure() — ignoring")
            return
        }
        await sdk._setAdvancedMatching(
            email: email, phone: phone,
            firstName: firstName, lastName: lastName,
            dateOfBirth: dateOfBirth
        )
    }

    /// Set RevenueCat app_user_id so webhook events can be linked
    /// to this device's attribution.
    public static func setUserId(_ userId: String) async {
        guard let sdk = getShared() else {
            _log("setUserId called before configure() — ignoring")
            return
        }
        await sdk._setUserId(userId)
    }

    /// Debug log for cases where no SDK instance exists yet.
    private static func _log(_ message: String) {
        #if DEBUG
        print("[AppRefer] \(message)")
        #endif
    }

    /// Get cached attribution result (no network call).
    public static func getAttribution() async -> Attribution? {
        guard let sdk = getShared() else { return nil }
        return await sdk._getAttribution()
    }

    /// Get the AppRefer device ID (for setting as RC subscriber attribute).
    public static func getDeviceId() async -> String? {
        guard let sdk = getShared() else { return nil }
        return await sdk._getDeviceId()
    }

    // MARK: - Actor-isolated accessors

    private func _getAttribution() -> Attribution? {
        storage.getCachedAttribution()
    }

    /// Nil while the Keychain can't be read or can't save a new id: a random id that
    /// was never saved would split this device's attribution in two.
    func _getDeviceId() -> String? {
        storage.deviceId()
    }

    // MARK: - Internal Implementation

    func _configure() async -> Attribution? {
        logger.info("AppRefer SDK initialized")

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

        // If match already attempted, report any ATT change, then return cached attribution
        if storage.isMatchRequestAttempted() {
            logger.info("Skipping match request: existing install detected.")
            return await syncTrackingConsent() ?? storage.getCachedAttribution()
        }

        // First run — resolve attribution
        return await resolveAttribution()
    }

    private func resolveAttribution() async -> Attribution? {
        guard let deviceId = storage.deviceId() else {
            // Not marked as attempted: the match runs on the next launch, once the
            // device id can be read or saved.
            logger.warn("Device id unavailable (Keychain); attribution deferred")
            return nil
        }
        let deviceInfo = AppReferDeviceInfo.collect()

        // AdServices token (Apple runs it without ATT); IDFA only when ATT is authorized.
        let consent = trackingStatus.current()
        let asaToken = AppReferAdServices.getToken()
        let idfa = consent == .granted ? AppReferAdServices.getIdfa() : nil

        var body: [String: Any] = [
            "device_id": deviceId,
            "device_info": deviceInfo,
            "sdk_version": AppReferVersion.current,
            "is_debug": config.debug,
            "tracking_consent": consent.rawValue,
        ]

        if let asaToken = asaToken {
            body["asa_token"] = asaToken
        }
        if let idfa = idfa {
            body["idfa"] = idfa
        }
        if let userId = storage.getUserId() {
            body["customer_user_id"] = userId
        }

        logger.info("Sending configure request...")
        guard let response = await client(for: consent).post("/api/track/configure", body: body) else {
            logger.error("Configure request failed")
            storage.setMatchRequestAttempted(true)
            return nil
        }
        storage.setReportedTrackingConsent(consent.rawValue)

        // Update kill switch from server
        let sdkEnabled = response["sdkEnabled"] as? Bool ?? true
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

        // The user may have answered the ATT prompt while this request was in flight.
        if let updated = await syncTrackingConsent() { return updated }
        return attribution
    }

    /// Tells the server when the ATT status differs from the one it last accepted. An
    /// install whose first configure failed is also registered this way. Returns the
    /// attribution the server now holds, or nil when nothing was sent or it failed
    /// (tried again on the next launch or activation).
    func syncTrackingConsent() async -> Attribution? {
        guard storage.isSdkEnabled(), storage.isMatchRequestAttempted(), !consentSyncInFlight else { return nil }
        let consent = trackingStatus.current()
        guard storage.reportedTrackingConsent() != consent.rawValue else { return nil }
        guard let deviceId = storage.deviceId() else { return nil }
        consentSyncInFlight = true
        defer { consentSyncInFlight = false }

        var body: [String: Any] = [
            "device_id": deviceId,
            "device_info": AppReferDeviceInfo.collect(),
            "sdk_version": AppReferVersion.current,
            "is_debug": config.debug,
            "tracking_consent": consent.rawValue,
        ]
        if consent == .granted, let idfa = AppReferAdServices.getIdfa() {
            body["idfa"] = idfa
        }
        if let userId = storage.getUserId() {
            body["customer_user_id"] = userId
        }

        logger.info("Reporting tracking consent: \(consent.rawValue)")
        guard let response = await client(for: consent).post("/api/track/configure", body: body) else {
            logger.warn("Tracking consent not reported; will retry")
            return nil
        }
        storage.setReportedTrackingConsent(consent.rawValue)
        if let enabled = response["sdkEnabled"] as? Bool, !enabled {
            storage.setSdkEnabled(false)
            return nil
        }
        guard let attrDict = response["attribution"] as? [String: Any],
              let attrData = try? JSONSerialization.data(withJSONObject: attrDict),
              let parsed = try? JSONDecoder().decode(Attribution.self, from: attrData) else { return nil }
        if let jsonString = String(data: attrData, encoding: .utf8) {
            storage.setAttributionCache(jsonString)
        }
        return parsed
    }

    // Test entry points for the private implementations.
    func _trackEventForTesting(_ name: String) async { await _trackEvent(name, properties: nil, revenue: nil, currency: nil) }
    func _setUserIdForTesting(_ id: String) async { await _setUserId(id) }
    func _setAdvancedMatchingForTesting(email: String) async {
        await _setAdvancedMatching(email: email, phone: nil, firstName: nil, lastName: nil, dateOfBirth: nil)
    }

    private func _trackEvent(
        _ eventName: String,
        properties: [String: Any]?,
        revenue: Double?,
        currency: String?
    ) async {
        guard storage.isSdkEnabled() else { return }
        guard let deviceId = storage.deviceId() else {
            logger.warn("Device id unavailable (Keychain); event \(eventName) not sent")
            return
        }
        var body: [String: Any] = [
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
        _ = await client(for: trackingStatus.current()).post("/api/track/event", body: body)
    }

    private func _setAdvancedMatching(
        email: String?,
        phone: String?,
        firstName: String?,
        lastName: String?,
        dateOfBirth: String?
    ) async {
        guard storage.isSdkEnabled() else { return }
        // Hashed PII for Meta's matching is only for advertising: never without ATT.
        guard trackingStatus.current() == .granted else {
            logger.info("Advanced matching skipped: tracking not authorized")
            return
        }

        var hashedData: [String: String] = [:]
        if let email = email { hashedData["em"] = AppReferHashing.hashEmail(email) }
        if let phone = phone { hashedData["ph"] = AppReferHashing.hashPhone(phone) }
        if let firstName = firstName { hashedData["fn"] = AppReferHashing.hashName(firstName) }
        if let lastName = lastName { hashedData["ln"] = AppReferHashing.hashName(lastName) }
        if let dateOfBirth = dateOfBirth { hashedData["db"] = AppReferHashing.hashDateOfBirth(dateOfBirth) }

        if hashedData.isEmpty { return }

        guard let deviceId = storage.deviceId() else {
            logger.warn("Device id unavailable (Keychain); advanced matching not sent")
            return
        }
        let body: [String: Any] = [
            "device_id": deviceId,
            "event_name": "_advanced_matching",
            "advanced_matching": hashedData,
        ]

        logger.info("Sending advanced matching data")
        _ = await trackingClient.post("/api/track/event", body: body)
    }

    private func _setUserId(_ userId: String) async {
        storage.setUserId(userId)
        logger.info("User ID set: \(userId)")

        // Sync userId to server so webhook userId fallback can find this attribution
        guard storage.isSdkEnabled(), let deviceId = storage.deviceId() else { return }
        let body: [String: Any] = [
            "device_id": deviceId,
            "event_name": "_set_user_id",
            "properties": ["user_id": userId],
        ]
        _ = await client(for: trackingStatus.current()).post("/api/track/event", body: body)
    }
}

