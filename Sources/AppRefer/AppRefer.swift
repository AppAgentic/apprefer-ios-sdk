import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// One AppRefer endpoint. Abstracted so tests can see which host each request used.
protocol AppReferPosting: Sendable {
    func post(_ path: String, body: [String: Any]) async -> [String: Any]?
    func event(_ body: [String: Any]) async -> Int?
    func cancel() async
    func cancelEvents() async
    func eventResponse(_ body: [String: Any]) async -> ProductEventResponse
}

extension AppReferPosting {
    func event(_ body: [String: Any]) async -> Int? {
        await post("/api/track/event", body: body) == nil ? nil : 200
    }
    func cancel() async {}
    func cancelEvents() async {}
    func eventResponse(_ body: [String: Any]) async -> ProductEventResponse {
        ProductEventResponse(status: await event(body), retryAfter: nil)
    }
}
extension AppReferHTTPClient: AppReferPosting {}

struct ProductEventResponse: Sendable { let status: Int?; let retryAfter: TimeInterval? }

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
    private nonisolated(unsafe) static var registeredApiKey: String?
    private nonisolated(unsafe) static var accountGeneration = 0
    static func accountEpoch() -> Int { lock.lock(); defer { lock.unlock() }; return accountGeneration }
    private static func advanceAccount() { lock.lock(); defer { lock.unlock() }; accountGeneration += 1 }

    private static func getShared() -> AppRefer? {
        lock.lock()
        defer { lock.unlock() }
        return _shared
    }

    private static func sharedForConfiguration(_ config: AppReferConfig) -> (AppRefer, Bool, Int) {
        lock.lock(); defer { lock.unlock() }
        registeredApiKey = config.apiKey
        if let sdk = _shared { return (sdk, false, accountGeneration) }
        let sdk = AppRefer(config: config)
        _shared = sdk
        return (sdk, true, accountGeneration)
    }

    /// SDK key passed to configure, used by optional modules.
    static func currentApiKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        return registeredApiKey
    }

    private var config: AppReferConfig
    private let storage: AppReferStorage
    private var logger: AppReferLogger
    private let trackingStatus: TrackingStatusProvider
    /// `trk.apprefer.com`, only for ATT-authorized installs.
    private var trackingClient: AppReferPosting
    /// `apprefer.com`, for everything else. Neither falls back to the other.
    private var firstPartyClient: AppReferPosting
    private var consentSyncTask: Task<Attribution?, Never>?
    private let conversionUpdater: ConversionValueUpdating
    private var conversionRefreshInFlight = false
    private var conversionRerunForced = false
    private var conversionRecheckScheduled = false
    private var consentRecheckRequested = false
    private var generation = 0
    private var eventGeneration = 0
    private var draining = false
    private var retryTask: Task<Void, Never>?
    private var lastConfigureFailed = false
    private var configurationTask: Task<Attribution?, Never>?

    init(
        config: AppReferConfig,
        storage: AppReferStorage = AppReferStorage(),
        trackingStatus: TrackingStatusProvider = LiveTrackingStatusProvider(),
        trackingClient: AppReferPosting? = nil,
        firstPartyClient: AppReferPosting? = nil,
        conversionUpdater: ConversionValueUpdating = LiveConversionValueUpdater()
    ) {
        self.conversionUpdater = conversionUpdater
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

        let (sdk, created, epoch) = sharedForConfiguration(config)
        if !created { await sdk.replaceConfiguration(config, expectedAccountEpoch: epoch) }
        await SupportAPI.shared.resumeRevocations(apiKey: apiKey)
        observeActivation()

        let attribution = await sdk._configure(expectedAccountEpoch: epoch)
        Task {
            await sdk.flushPendingEvents()
            await sdk.refreshConversionValue(force: false)
        }
        return attribution
    }

    /// Organic is returned only after an explicit successful server answer.
    public static func configureResult(
        apiKey: String, userId: String? = nil, debug: Bool = false, logLevel: Int = 1
    ) async -> AppReferAttributionResult {
        _ = await configure(apiKey: apiKey, userId: userId, debug: debug, logLevel: logLevel)
        guard let sdk = getShared() else { return .failed(AppReferAttributionError.unavailable) }
        return await sdk.attributionResult()
    }

    /// Asks AppRefer for this install's SKAdNetwork / AdAttributionKit conversion value
    /// and sets it on the device if it went up. AppRefer does this by itself on launch,
    /// when the app becomes active, after trial/revenue events and AppRefer Billing
    /// purchases; call it after a purchase made elsewhere (e.g. RevenueCat) to set it sooner.
    public static func updateConversionValue() async {
        await getShared()?.refreshConversionValue(force: true)
    }

    /// Fire-and-forget refresh, e.g. after an AppRefer Billing purchase.
    static func conversionValueMayHaveChanged() {
        guard let sdk = getShared() else { return }
        Task { await sdk.refreshConversionValue(force: true) }
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
            Task {
                if let key = currentApiKey() { await SupportAPI.shared.resumeRevocations(apiKey: key) }
                await AppRefer.trackingConsentDidChange()
                await getShared()?.refreshConversionValue(force: false)
                await getShared()?.flushPendingEvents()
            }
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
        _ = await trackEventResult(eventName, properties: properties, revenue: revenue, currency: currency)
    }

    /// Persist before sending. Delivery is at least once; eventId stays stable on retries.
    public static func trackEventResult(
        _ eventName: String, properties: [String: Any]? = nil,
        revenue: Double? = nil, currency: String? = nil
    ) async -> AppReferEventResult {
        guard let sdk = getShared() else { return .dropped }
        // Deep-copy properties via JSON round-trip to prevent callers from
        // mutating the dictionary while JSONSerialization walks it inside the actor.
        let safeCopy = properties.flatMap { Self.jsonSafeCopy($0) }
        return await sdk._trackEvent(eventName, properties: safeCopy, revenue: revenue, currency: currency)
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
            AppReferStorage().setUserId(userId)
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

    /// Clear account state; install attribution and device id are retained.
    /// Also call AppReferBilling.logOut() if your app uses Billing.
    public static func reset() async {
        advanceAccount()
        if let sdk = getShared() { await sdk._reset() }
        else { await clearPendingEvents() }
        AppReferStorage().clearUser()
        await SupportAPI.shared.reset()
        #if os(iOS)
        await AppReferSupport.shared.dismissForReset()
        #endif
        Task { await SupportAPI.shared.retryRevocations() }
    }

    public static func clearPendingEvents() async {
        if let sdk = getShared() { await sdk._clearPendingEvents() }
        else { AppReferStorage().pendingEvents = nil }
    }

    func _clearPendingEvents() async {
        eventGeneration += 1
        retryTask?.cancel()
        retryTask = nil
        storage.pendingEvents = nil
        draining = false
        await trackingClient.cancelEvents()
        await firstPartyClient.cancelEvents()
    }

    func replaceConfiguration(_ newConfig: AppReferConfig, expectedAccountEpoch: Int? = nil, trackingClient: AppReferPosting? = nil, firstPartyClient: AppReferPosting? = nil) async {
        guard expectedAccountEpoch == nil || expectedAccountEpoch == Self.accountEpoch() else { return }
        guard newConfig.apiKey != config.apiKey || newConfig.userId != config.userId || newConfig.debug != config.debug || newConfig.logLevel != config.logLevel || trackingClient != nil || firstPartyClient != nil else { return }
        configurationTask?.cancel(); configurationTask = nil
        generation += 1
        let epoch = generation
        eventGeneration += 1
        draining = false
        retryTask?.cancel(); retryTask = nil
        consentSyncTask?.cancel(); consentSyncTask = nil
        await self.trackingClient.cancel()
        await self.firstPartyClient.cancel()
        guard epoch == generation, expectedAccountEpoch == nil || expectedAccountEpoch == Self.accountEpoch() else { return }
        config = newConfig
        logger = AppReferLogger(debug: newConfig.debug, logLevel: newConfig.logLevel)
        self.trackingClient = trackingClient ?? AppReferHTTPClient(primaryURL: AppReferConfig.trackingURL, apiKey: newConfig.apiKey, logger: logger)
        self.firstPartyClient = firstPartyClient ?? AppReferHTTPClient(primaryURL: AppReferConfig.backendURL, apiKey: newConfig.apiKey, logger: logger)
        scheduleRetry()
    }


    func _reset() async {
        configurationTask?.cancel(); configurationTask = nil
        generation += 1
        consentSyncTask?.cancel()
        consentSyncTask = nil
        consentRecheckRequested = false
        conversionRerunForced = false
        storage.clearUser()
        await _clearPendingEvents()
    }

    func attributionResult() -> AppReferAttributionResult {
        if let attribution = storage.getCachedAttribution() {
            if attribution.trackingDecisionPending && attribution.matchType != "adservices" { return .pending }
            return attribution.network.lowercased() == "organic" ? .organic : .attributed(attribution)
        }
        if storage.organicConfirmed { return .organic }
        return .failed(AppReferAttributionError.unavailable)
    }

    private func recordOrganic(_ response: [String: Any]) {
        if (response["attribution"] as? [String: Any])?["trackingDecisionPending"] as? Bool == true {
            storage.organicConfirmed = false
            return
        }
        if response["attribution"] is NSNull || response["organic"] as? Bool == true ||
            (response["attribution"] as? [String: Any])?["network"] as? String == "organic" {
            storage.organicConfirmed = true
        }
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

    func _configure(expectedAccountEpoch: Int? = nil) async -> Attribution? {
        if let task = configurationTask { return await task.value }
        let epoch = generation
        let task = Task { await self.runConfiguration(expectedAccountEpoch: expectedAccountEpoch) }
        configurationTask = task
        let result = await task.value
        if epoch == generation { configurationTask = nil }
        return result
    }
    private func runConfiguration(expectedAccountEpoch: Int? = nil) async -> Attribution? {
        guard expectedAccountEpoch == nil || expectedAccountEpoch == Self.accountEpoch() else { return nil }
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
        lastConfigureFailed = false
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
        let epoch = generation
        guard let response = await client(for: consent).post("/api/track/configure", body: body) else {
            guard epoch == generation else { return nil }
            lastConfigureFailed = true
            logger.error("Configure request failed")
            storage.setMatchRequestAttempted(true)
            return nil
        }

        guard epoch == generation, !Task.isCancelled else { return nil }
        recordOrganic(response)
        lastConfigureFailed = false
        // Update kill switch from server
        let sdkEnabled = response["sdkEnabled"] as? Bool ?? true
        storage.setSdkEnabled(sdkEnabled)
        if !sdkEnabled {
            await _clearPendingEvents()
            logger.info("SDK disabled by server")
            storage.setMatchRequestAttempted(true)
            return nil
        }
        storage.setReportedTrackingConsent(consent.rawValue)

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
        if let running = consentSyncTask {
            // The running sync checks again before it ends, so a newer answer isn't lost;
            // wait for it so the caller sees the attribution it produced.
            consentRecheckRequested = true
            return await running.value
        }
        let epoch = generation
        let task = Task { await self.runConsentSync() }
        consentSyncTask = task
        let result = await task.value
        guard epoch == generation else { return nil }
        consentSyncTask = nil
        if consentRecheckRequested { return await syncTrackingConsent() ?? result }
        return result
    }

    private func runConsentSync() async -> Attribution? {
        var latest: Attribution?
        repeat {
            consentRecheckRequested = false
            if let updated = await reportTrackingConsentIfChanged() { latest = updated }
        } while consentRecheckRequested
        return latest
    }

    private func reportTrackingConsentIfChanged() async -> Attribution? {
        guard storage.isSdkEnabled(), storage.isMatchRequestAttempted() else { return nil }
        let consent = trackingStatus.current()
        let previouslyAccepted = storage.reportedTrackingConsent()
        let cached = storage.getCachedAttribution()
        guard previouslyAccepted != consent.rawValue || (cached?.trackingDecisionPending == true && cached?.matchType != "adservices") else { return nil }
        guard let deviceId = storage.deviceId() else { return nil }

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
        // The server has never accepted a configure from this install (the first open
        // failed): send what a first open sends so it can still be attributed.
        if previouslyAccepted == nil, let asaToken = AppReferAdServices.getToken() {
            body["asa_token"] = asaToken
        }
        if let userId = storage.getUserId() {
            body["customer_user_id"] = userId
        }

        logger.info("Reporting tracking consent: \(consent.rawValue)")
        let epoch = generation
        guard let response = await client(for: consent).post("/api/track/configure", body: body) else {
            guard epoch == generation else { return nil }
            lastConfigureFailed = true
            logger.warn("Tracking consent not reported; will retry")
            return nil
        }
        guard epoch == generation, !Task.isCancelled else { return nil }
        recordOrganic(response)
        lastConfigureFailed = false
        if let enabled = response["sdkEnabled"] as? Bool, !enabled {
            storage.setSdkEnabled(false)
            await _clearPendingEvents()
            return nil
        }
        storage.setReportedTrackingConsent(consent.rawValue)
        guard let attrDict = response["attribution"] as? [String: Any],
              let attrData = try? JSONSerialization.data(withJSONObject: attrDict),
              let parsed = try? JSONDecoder().decode(Attribution.self, from: attrData) else { return nil }
        if let jsonString = String(data: attrData, encoding: .utf8) {
            storage.setAttributionCache(jsonString)
        }
        return parsed
    }

    private static let trialEvents: Set<String> = ["startTrial", "trial_started", "StartTrial", "start_trial"]

    /// Postbacks cover 35 days after install; after that the value can't matter.
    private static let conversionWindow: TimeInterval = 35 * 86400
    /// Unforced refreshes (launch, activation) at most this often.
    private static let conversionRefreshInterval: TimeInterval = 10 * 60

    /// Registers the install for ad attribution on the first call (value 0, low, which Apple
    /// recommends at first launch), then raises the value whenever AppRefer reports a
    /// higher one. Always the first-party host: the value is computed from first-party
    /// data and only reaches ad networks through Apple's anonymous postbacks.
    func refreshConversionValue(force: Bool, allowRecheck: Bool = true) async {
        guard storage.isSdkEnabled() else { return }
        if let firstRun = storage.firstRunDate(), Date().timeIntervalSince(firstRun) > Self.conversionWindow { return }
        if conversionRefreshInFlight {
            // A purchase may have landed after the running check read its value: run again after it.
            if force { conversionRerunForced = true }
            return
        }
        conversionRefreshInFlight = true
        var forced = force
        repeat {
            conversionRerunForced = false
            let raised = await refreshConversionValueOnce(force: forced)
            // A purchase made outside AppRefer Billing reaches AppRefer through its webhook a moment
            // later: if a forced check found nothing new, look once more after 90 seconds.
            if forced, !raised, allowRecheck, !conversionRecheckScheduled {
                conversionRecheckScheduled = true
                Task {
                    try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
                    await self.finishScheduledRecheck()
                }
            }
            forced = true
        } while conversionRerunForced
        conversionRefreshInFlight = false
    }

    /// Through the guarded path (enabled, window, one check at a time), without scheduling another.
    private func finishScheduledRecheck() async {
        conversionRecheckScheduled = false
        await refreshConversionValue(force: true, allowRecheck: false)
    }

    /// One check; true when the value went up.
    private func refreshConversionValueOnce(force: Bool) async -> Bool {
        var current = storage.conversionValue()
        if current == nil {
            await conversionUpdater.update(fine: 0, coarse: .low)
            storage.setConversionValue(fine: 0, coarse: AppReferCoarseValue.low.rawValue)
            current = (0, AppReferCoarseValue.low.rawValue)
        }
        if !force, let checked = storage.conversionCheckedAt(), Date().timeIntervalSince(checked) < Self.conversionRefreshInterval { return false }
        guard let deviceId = storage.deviceId() else { return false }
        var body: [String: Any] = ["device_id": deviceId]
        // Lets AppRefer tell a reinstall (same Keychain id, new first run) from the old install.
        if let firstRun = storage.firstRunDate() {
            body["installed_at"] = ISO8601DateFormatter().string(from: firstRun)
        }
        guard let response = await firstPartyClient.post("/api/track/conversion-value", body: body),
              let fine = response["fine"] as? Int,
              let coarse = (response["coarse"] as? String).flatMap(AppReferCoarseValue.init(rawValue:)) else { return false }
        storage.setConversionCheckedAt(Date())
        // Compare with what is stored now, not before the request.
        current = storage.conversionValue() ?? current
        let lastFine = current?.fine ?? 0
        let lastCoarse = current.flatMap { AppReferCoarseValue(rawValue: $0.coarse) } ?? .low
        guard fine > lastFine || coarse > lastCoarse else { return false }
        let newFine = max(fine, lastFine)
        let newCoarse = max(coarse, lastCoarse)
        await conversionUpdater.update(fine: newFine, coarse: newCoarse)
        storage.setConversionValue(fine: newFine, coarse: newCoarse.rawValue)
        logger.info("Conversion value set: \(newFine) (\(newCoarse.rawValue))")
        return true
    }

    // Test entry points for the private implementations.
    func _getAttributionForTesting() -> Attribution? { storage.getCachedAttribution() }
    func _trackEventForTesting(_ name: String) async { await _trackEvent(name, properties: nil, revenue: nil, currency: nil) }
    func _setUserIdForTesting(_ id: String) async { await _setUserId(id) }
    func _setAdvancedMatchingForTesting(email: String) async {
        await _setAdvancedMatching(email: email, phone: nil, firstName: nil, lastName: nil, dateOfBirth: nil)
    }

    @discardableResult
    func _trackEvent(
        _ eventName: String, properties: [String: Any]?, revenue: Double?, currency: String?
    ) async -> AppReferEventResult {
        guard storage.isSdkEnabled(), let deviceId = storage.deviceId() else { return .dropped }
        let id = UUID().uuidString
        var body: [String: Any] = ["device_id": deviceId, "event_name": eventName, "eventId": id]
        if let properties { body["properties"] = properties }
        if let revenue { body["revenue"] = revenue }
        if let currency { body["currency"] = currency }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .dropped }
        guard var events = loadEvents() else { return .dropped }
        events.append(PendingProductEvent(id: id, body: data, created: Date(), attempts: 0, nextAttempt: .distantPast))
        guard saveEvents(events) else { return .dropped }
        let epoch = eventGeneration
        let statuses = await flushPendingEvents(only: id)
        guard epoch == eventGeneration else { return loadEvents()?.contains(where: { $0.id == id }) == true ? .queued : .dropped }
        if (revenue ?? 0) > 0 || Self.trialEvents.contains(eventName) {
            Task { await self.refreshConversionValue(force: true) }
        }
        guard epoch == eventGeneration else { return loadEvents()?.contains(where: { $0.id == id }) == true ? .queued : .dropped }
        if let status = statuses[id] { return (200..<300).contains(status) ? .sent : .dropped }
        return .queued
    }

    private func loadEvents() -> [PendingProductEvent]? {
        do {
            let events = try storage.readPendingEvents().map { try JSONDecoder().decode([PendingProductEvent].self, from: $0) } ?? []
            return Array(events.filter { Date().timeIntervalSince($0.created) < 7 * 86400 }.suffix(1000))
        } catch {
            do {
                try storage.quarantinePendingEvents()
                logger.warn("Corrupt product-event queue quarantined")
                return []
            } catch {
                logger.warn("Product-event queue unavailable")
                return nil
            }
        }
    }

    @discardableResult
    private func saveEvents(_ events: [PendingProductEvent]) -> Bool {
        do {
            try storage.writePendingEvents(JSONEncoder().encode(Array(events.suffix(1000))))
            return true
        } catch {
            logger.warn("Product-event queue could not be saved")
            return false
        }
    }

    /// Only the queue retries events; the transport performs one attempt.
    @discardableResult
    func flushPendingEvents(only eventId: String? = nil) async -> [String: Int] {
        guard !draining, storage.isSdkEnabled() else {
            if !storage.isSdkEnabled() { storage.pendingEvents = nil }
            return [:]
        }
        draining = true
        let epoch = eventGeneration
        defer {
            if epoch == eventGeneration { draining = false; scheduleRetry() }
        }
        var results: [String: Int] = [:]
        guard let pending = loadEvents(), saveEvents(pending) else { return results }
        for event in pending where event.nextAttempt <= Date() && (eventId == nil || event.id == eventId) {
            guard epoch == eventGeneration, !Task.isCancelled, storage.isSdkEnabled() else { break }
            guard let body = try? JSONSerialization.jsonObject(with: event.body) as? [String: Any] else { continue }
            let response = await client(for: trackingStatus.current()).eventResponse(body)
            let status = response.status
            guard epoch == eventGeneration, !Task.isCancelled else { break }
            guard var events = loadEvents() else { break }
            let retryable = status == nil || status == 408 || status == 429 || (500..<600).contains(status ?? 0)
            if let status, !retryable {
                events.removeAll { $0.id == event.id }
                results[event.id] = status
            } else if let i = events.firstIndex(where: { $0.id == event.id }) {
                events[i].attempts += 1
                let delay = max(response.retryAfter ?? 0, min(3600, pow(2, Double(min(events[i].attempts, 12)))))
                let next = Date().addingTimeInterval(delay)
                // The first retryable response pauses the whole backlog.
                for j in events.indices { events[j].nextAttempt = max(events[j].nextAttempt, next) }
            }
            saveEvents(events)
            if retryable { break }
        }
        return results
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard let next = loadEvents()?.map(\.nextAttempt).min() else { retryTask = nil; return }
        let delay = min(3600, max(0.1, next.timeIntervalSinceNow))
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.flushPendingEvents()
        }
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

