import Foundation
import CryptoKit
import Security

/// What the event queue and notification handling may read synchronously: the current
/// install, account epoch and identity serial, and the credential header for events.
struct EngagementSnapshot: Equatable, Sendable {
    let slot: String
    let installId: String
    /// nil while an account change is in progress or not yet confirmed by the server.
    let accountEpoch: Int?
    /// Advances on every reset, logout, sign-in, deletion and server-side account change.
    let serial: Int
    let header: String
    let trackedEvents: Set<String>?
    /// `slot:installId:serial:epoch`: queued events carry it and get the header only while it is
    /// current. The epoch is part of it (and is sent as `X-AppRefer-Install-Epoch`), so an event
    /// queued under one account never matches after a cold restart that learned another, and
    /// the server refuses it if the install moved on before the SDK knew.
    var stamp: String { "\(slot):\(installId):\(serial):\(accountEpoch.map(String.init) ?? "-")" }
}

/// Told (synchronously, on the client's executor) whenever the install's identity changes, so
/// the notification layer can drop what belongs to the old one (local snoozes, held navigation).
final class EngagementIdentityObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    func set(_ handler: (@Sendable () -> Void)?) { lock.lock(); self.handler = handler; lock.unlock() }
    func fire() { lock.lock(); let h = handler; lock.unlock(); h?() }
}

final class EngagementSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EngagementSnapshot?
    func get() -> EngagementSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ snapshot: EngagementSnapshot?) { lock.lock(); value = snapshot; lock.unlock() }
}

/// The device's current settings the server should know (all optional reads, never prompts).
struct EngagementDeviceState: Equatable, Sendable {
    var timezone: String
    var locale: String?
    var collectionEnabled: Bool
    var permission: AppReferNotificationPermission
}

/// One queued device receipt. No secret: the token is narrow proof for one message.
struct PendingEngagementReceipt: Codable, Equatable {
    let slot: String
    let installId: String
    let accountEpoch: Int
    let serial: Int
    let messageId: String
    let token: String
    let kind: String
    let actionId: String?
    let occurredAt: Date
    var attempts: Int
}

/// Lifecycle engagement client: install registration, credential storage, device state,
/// preferences, account binding and receipts. Every identity operation runs in order on one
/// serial chain, so a logout can never overtake a sign-in that started before it (or the
/// reverse), and the server always ends in the state of the last call. Each call also checks
/// a generation number after every await: a result that arrives after a reset, logout,
/// sign-in or key switch is discarded instead of applied to the next account.
actor EngagementClient {
    static let shared = EngagementClient()

    private let baseURL: String
    private let session: URLSession
    private let keychain: DeviceIdKeychain
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let deviceState: @Sendable () async -> EngagementDeviceState
    private let pushEnvironment: @Sendable () -> String
    private let deviceId: @Sendable () -> String?
    nonisolated let snapshot = EngagementSnapshotBox()
    nonisolated let identityObserver = EngagementIdentityObserver()

    init(baseURL: String = AppReferConfig.backendURL,
         session: URLSession = URLSession(configuration: .ephemeral),
         keychain: DeviceIdKeychain = LiveDeviceIdKeychain(),
         defaults: UserDefaults = .standard,
         now: @escaping @Sendable () -> Date = { Date() },
         deviceState: @escaping @Sendable () async -> EngagementDeviceState = { await EngagementClient.liveDeviceState() },
         pushEnvironment: @escaping @Sendable () -> String = { PushEnvironmentSetting.shared.effective.rawValue },
         deviceId: @escaping @Sendable () -> String? = { AppRefer.supportDeviceId() }) {
        self.baseURL = baseURL; self.session = session; self.keychain = keychain; self.defaults = defaults
        self.now = now; self.deviceState = deviceState; self.pushEnvironment = pushEnvironment; self.deviceId = deviceId
    }

    // MARK: State

    private(set) var status: AppReferEngagementStatus = .notStarted
    private var apiKey: String?
    private var explicitKey = false
    private var started = false
    private var options = AppReferEngagementOptions()
    private var credential: Credential?
    /// Persisted with the install id whenever known, so a cold start can tell that the server's
    /// epoch moved while the app wasn't running.
    private var accountEpoch: Int? {
        didSet { if let accountEpoch, let credential { defaults.set("\(credential.installId):\(accountEpoch)", forKey: key("epoch")) } }
    }
    private var knownEpoch: Int? {
        if let accountEpoch { return accountEpoch }
        guard let credential, let saved = defaults.string(forKey: key("epoch")) else { return nil }
        let parts = saved.split(separator: ":")
        return parts.count == 2 && parts[0] == Substring(credential.installId) ? Int(parts[1]) : nil
    }
    private var pushToken: String?
    private var generation = 0
    private var registrationRetried = false
    private var tail: Task<Void, Never>?

    struct Credential: Codable, Equatable { let installId: String; let secret: String; var pendingDelete: Bool? }

    private var slot: String? { apiKey.map(Self.slot(for:)) }
    static func slot(for apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs `op` after every earlier operation has finished.
    private func serially<T: Sendable>(_ op: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { () -> T in
            _ = await previous?.value
            return await op()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // Per-slot persisted state (no secrets).
    private func key(_ name: String) -> String { "apprefer_engagement_\(name)_\(slot ?? "none")" }
    /// Every write is an identity change: observers drop what belonged to the previous identity.
    private var serial: Int {
        get { defaults.integer(forKey: key("serial")) }
        set { defaults.set(newValue, forKey: key("serial")); identityObserver.fire() }
    }
    private var pendingLogout: Bool {
        get { defaults.bool(forKey: key("pending_logout")) }
        set { defaults.set(newValue, forKey: key("pending_logout")); if !newValue { pendingLogoutEpoch = nil } }
    }
    /// The epoch the saved logout was made under (nil: not known when it was made).
    private var pendingLogoutEpoch: Int? {
        get { defaults.object(forKey: key("pending_logout_epoch")) as? Int }
        set { defaults.set(newValue, forKey: key("pending_logout_epoch")) }
    }
    private var disabledUntil: Date? {
        get { defaults.object(forKey: key("disabled_until")) as? Date }
        set { defaults.set(newValue, forKey: key("disabled_until")) }
    }
    private var lastSync: (hash: String, at: Date)? {
        get {
            guard let hash = defaults.string(forKey: key("sync_hash")), let at = defaults.object(forKey: key("sync_at")) as? Date else { return nil }
            return (hash, at)
        }
        set {
            defaults.set(newValue?.hash, forKey: key("sync_hash"))
            defaults.set(newValue?.at, forKey: key("sync_at"))
        }
    }

    private func publish() {
        guard let slot, let credential, credential.pendingDelete != true, case .active = status else {
            snapshot.set(nil)
            sharedState?.setIdentity(nil)
            return
        }
        snapshot.set(EngagementSnapshot(slot: slot, installId: credential.installId, accountEpoch: accountEpoch, serial: serial,
                                        header: "\(credential.installId).\(credential.secret)", trackedEvents: options.trackedEvents))
        sharedState?.setIdentity(.init(installId: credential.installId, accountEpoch: accountEpoch))
    }
    private var sharedState: AppReferNotificationSharedState? { options.appGroup.map(AppReferNotificationSharedState.init(appGroup:)) }

    /// Identity changed (or is about to): queued events lose the header, pending receipts and
    /// navigation for the old identity are dropped, and nothing matches until the server
    /// confirms the new epoch.
    private func beginIdentityChange() {
        generation += 1
        serial += 1
        accountEpoch = nil
        dropReceipts { _ in true }
        publish()
    }

    // MARK: Start

    func start(apiKey: String, explicit: Bool, options: AppReferEngagementOptions) async -> AppReferEngagementStatus {
        await serially { await self.runStart(apiKey: apiKey, explicit: explicit, options: options) }
    }

    private func runStart(apiKey: String, explicit: Bool, options: AppReferEngagementOptions) async -> AppReferEngagementStatus {
        if self.apiKey != apiKey {
            // Another app or environment: its own credential slot; nothing carries over.
            generation += 1
            credential = nil
            accountEpoch = nil
            registrationRetried = false
            status = .pending
            publish()
            identityObserver.fire()
        }
        self.apiKey = apiKey
        self.explicitKey = explicit
        self.options = options
        started = true
        return await activate()
    }

    /// Called by `AppRefer.configure` with its key: an implicitly keyed engagement follows it.
    func configurationChanged(apiKey: String) async {
        guard started, !explicitKey, apiKey != self.apiKey else { return }
        _ = await start(apiKey: apiKey, explicit: false, options: options)
    }

    /// Foreground: retry what is pending, refresh device state, flush receipts.
    func becameActive() async {
        guard started else { return }
        _ = await serially { await self.activate() }
    }

    private func activate() async -> AppReferEngagementStatus {
        guard let apiKey else { return .notStarted }
        if let until = disabledUntil, until > now() { status = .disabled; publish(); return status }
        let gen = generation
        if credential == nil {
            switch loadCredential() {
            case .found(let saved): credential = saved
            case .missing: break
            case .unavailable: status = .pending; publish(); return status
            }
        }
        if credential?.pendingDelete == true {
            guard await sendDelete(apiKey: apiKey, gen: gen) else { status = .pending; publish(); return status }
        }
        if credential == nil {
            guard await register(apiKey: apiKey, gen: gen) else { publish(); return status }
        }
        guard gen == generation, let credential else { return status }
        if defaults.bool(forKey: Self.pendingLogoutAnyKey) {
            defaults.removeObject(forKey: Self.pendingLogoutAnyKey)
            // Made before this slot started in that process: it applies to the identity this
            // slot last knew (persisted), never to one the server moved to afterwards.
            let epoch = knownEpoch
            pendingLogout = true
            pendingLogoutEpoch = epoch
            serial += 1
        }
        if pendingLogout {
            var expected = pendingLogoutEpoch
            if expected == nil {
                // Nothing was known about this install's identity when the logout was saved
                // (it had never been verified here): log out whatever it is now.
                let (code, body, _) = await send("GET", "/api/engagement/v1/installs/me", body: nil, apiKey: apiKey, credential: credential)
                guard gen == generation else { return status }
                expected = code == 200 ? (body?["install"] as? [String: Any])?["accountEpoch"] as? Int : nil
                if expected == nil { if !handleFailure(code, body) { status = .pending }; publish(); return status }
            }
            let (code, body, _) = await send("POST", "/api/engagement/v1/installs/me/logout", body: ["expectedEpoch": expected!], apiKey: apiKey, credential: credential)
            guard gen == generation else { return status }
            // 409: the install already left that identity (another sign-in or a backend
            // change): the logout's purpose is met and it must not detach the newer one.
            if code == 200 || code == 409 { pendingLogout = false; if code == 200 { accountEpoch = body?["accountEpoch"] as? Int } }
            else if handleFailure(code, body) { return status }
            else { status = .pending; publish(); return status }
        }
        // Verify the credential and learn the account epoch.
        let (code, body, _) = await send("GET", "/api/engagement/v1/installs/me", body: nil, apiKey: apiKey, credential: credential)
        guard gen == generation else { return status }
        guard code == 200, let install = body?["install"] as? [String: Any] else {
            if code == 401, !registrationRetried {
                // Erased or deleted on the server: forget it and register once more.
                registrationRetried = true
                forgetCredential()
                return await activate()
            }
            if !handleFailure(code, body) { status = .pending }
            publish()
            return status
        }
        observeEpoch(install["accountEpoch"] as? Int)
        status = .active(installId: credential.installId)
        publish()
        await syncDevice(force: false)
        await flushReceipts()
        return status
    }

    private enum Loaded { case found(Credential), missing, unavailable }
    private func credentialKey() -> String { "apprefer_engagement_install_\(slot ?? "none")" }

    private func loadCredential() -> Loaded {
        switch keychain.load(key: credentialKey()) {
        case .found(let raw):
            guard let data = raw.data(using: .utf8), let saved = try? JSONDecoder().decode(Credential.self, from: data) else {
                keychain.delete(key: credentialKey())
                return .missing
            }
            return .found(saved)
        case .notFound: return .missing
        // Before first unlock or a failing Keychain: never mint a second install meanwhile.
        case .unavailable, .failed: return .unavailable
        }
    }

    private func saveCredential(_ value: Credential, adding: Bool) -> OSStatus {
        guard let data = try? JSONEncoder().encode(value) else { return errSecParam }
        let text = String(decoding: data, as: UTF8.self)
        if adding { return keychain.add(key: credentialKey(), value: text) }
        return keychain.save(key: credentialKey(), value: text) ? errSecSuccess : errSecIO
    }

    private func forgetCredential() {
        keychain.delete(key: credentialKey())
        defaults.removeObject(forKey: key("epoch"))
        credential = nil
        accountEpoch = nil
        lastSync = nil
        serial += 1
        dropReceipts { _ in true }
        publish()
    }

    private func register(apiKey: String, gen: Int) async -> Bool {
        let state = await deviceState()
        var body: [String: Any] = ["platform": "ios", "timezone": state.timezone, "collectionEnabled": state.collectionEnabled]
        if let locale = state.locale { body["locale"] = locale }
        if let id = deviceId() { body["deviceId"] = id }
        let (code, json, _) = await send("POST", "/api/engagement/v1/installs", body: body, apiKey: apiKey, credential: nil)
        guard code == 201, let installId = json?["installId"] as? String, let secret = json?["installSecret"] as? String else {
            if !handleFailure(code, json) { status = .pending }
            return false
        }
        let minted = Credential(installId: installId, secret: secret, pendingDelete: nil)
        // A reset, logout or key switch while this was in flight: this install is anonymous
        // and never bound to anyone, but it belongs to a state that no longer exists. Remove it.
        guard gen == generation, self.apiKey == apiKey else {
            _ = await send("DELETE", "/api/engagement/v1/installs/me", body: nil, apiKey: apiKey, credential: minted)
            return false
        }
        let saved = saveCredential(minted, adding: true)
        if saved == errSecDuplicateItem, case .found(let existing) = loadCredential() {
            // Another start saved one first: keep it, drop ours.
            _ = await send("DELETE", "/api/engagement/v1/installs/me", body: nil, apiKey: apiKey, credential: minted)
            credential = existing
            return true
        }
        guard saved == errSecSuccess else {
            // Without a saved credential every launch would mint another install: remove it.
            _ = await send("DELETE", "/api/engagement/v1/installs/me", body: nil, apiKey: apiKey, credential: minted)
            status = .pending
            return false
        }
        credential = minted
        accountEpoch = 0
        serial += 1
        lastSync = nil
        return true
    }

    /// Server-side account changes (backend bind/unbind) also move the epoch. Compared with the
    /// last epoch known for this install, persisted across launches: a change made while the app
    /// wasn't running still advances the serial, so nothing queued for the old identity matches.
    private func observeEpoch(_ epoch: Int?) {
        guard let epoch else { return }
        if knownEpoch != epoch { serial += 1 }
        if accountEpoch != epoch { accountEpoch = epoch }
    }

    /// True when the response was handled as a terminal state (disabled, invalid install).
    @discardableResult
    private func handleFailure(_ code: Int?, _ body: [String: Any]?) -> Bool {
        let errorCode = (body?["error"] as? [String: Any])?["code"] as? String
        if code == 404, errorCode == "ENGAGEMENT_DISABLED" {
            disabledUntil = now().addingTimeInterval(6 * 3600)
            status = .disabled
            publish()
            return true
        }
        if code == 401, errorCode == "INVALID_INSTALL" {
            forgetCredential()
            status = .pending
            return true
        }
        return false
    }

    // MARK: Device state

    func setPushToken(_ hex: String?) async {
        pushToken = hex
        await serially { await self.syncDevice(force: false) }
    }

    func refreshDeviceState() async {
        await serially { await self.syncDevice(force: false) }
    }

    func capabilities() -> [String: Any] {
        ["schema": 1, "images": options.notificationServiceExtension, "actions": Self.supportsActions]
    }
    static var supportsActions: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    private func syncDevice(force: Bool) async {
        guard case .active = status, let apiKey, let credential else { return }
        let gen = generation
        let state = await deviceState()
        var body: [String: Any] = [
            "timezone": state.timezone, "collectionEnabled": state.collectionEnabled,
            "notificationPermission": state.permission.rawValue, "capabilities": capabilities(),
        ]
        if let locale = state.locale { body["locale"] = locale }
        if let pushToken { body["pushToken"] = pushToken; body["pushEnvironment"] = pushEnvironment() }
        let hash = Self.hash(body)
        if !force, let last = lastSync, last.hash == hash, now().timeIntervalSince(last.at) < 86_400 { return }
        let (code, json, _) = await send("PATCH", "/api/engagement/v1/installs/me", body: body, apiKey: apiKey, credential: credential)
        guard gen == generation else { return }
        if code == 200 {
            lastSync = (hash, now())
            let before = serial
            observeEpoch((json?["install"] as? [String: Any])?["accountEpoch"] as? Int)
            if before != serial { publish() }
        } else {
            handleFailure(code, json)
        }
    }

    static func hash(_ body: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func liveDeviceState() async -> EngagementDeviceState {
        let locale = Locale.preferredLanguages.first.map { $0.replacingOccurrences(of: "_", with: "-") }
            .flatMap { $0.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$"#, options: .regularExpression) != nil ? $0 : nil }
        return EngagementDeviceState(
            timezone: TimeZone.current.identifier, locale: locale,
            collectionEnabled: AppReferStorage().isCollectionEnabled(),
            permission: await EngagementPermission.current())
    }

    // MARK: Identity

    func identify(assertion: String) async throws {
        try await serially { await self.runIdentify(assertion) }.get()
    }

    private func runIdentify(_ assertion: String) async -> Result<Void, AppReferEngagementError> {
        guard case .active = status, let apiKey, let credential else { return .failure(.notStarted) }
        // The identity this sign-in replaces: the server refuses it (409) if that changed meanwhile.
        if knownEpoch == nil { _ = await reverify(gen: generation) }
        guard let expected = knownEpoch else { return .failure(.unavailable) }
        beginIdentityChange()
        let gen = generation
        let (code, body, _) = await send("POST", "/api/engagement/v1/installs/me/account", body: ["assertion": assertion, "expectedEpoch": expected], apiKey: apiKey, credential: credential)
        guard gen == generation else { return .failure(.identityChanged) }
        if code == 200, let epoch = body?["accountEpoch"] as? Int {
            // A sign-in that succeeds also supersedes an unsent logout.
            pendingLogout = false
            accountEpoch = epoch
            lastSync = nil
            publish()
            await syncDevice(force: true)
            return .success(())
        }
        let error: AppReferEngagementError = code == 401 && Self.code(body) == "INVALID_ASSERTION" ? .invalidAssertion : failure(code, body)
        // Not bound: learn the (unchanged) epoch again.
        if !handleFailure(code, body) { _ = await reverify(gen: gen) }
        return .failure(error)
    }

    private func reverify(gen: Int) async -> Bool {
        guard let apiKey, let credential else { return false }
        let (code, body, _) = await send("GET", "/api/engagement/v1/installs/me", body: nil, apiKey: apiKey, credential: credential)
        guard gen == generation, code == 200 else { return false }
        observeEpoch((body?["install"] as? [String: Any])?["accountEpoch"] as? Int)
        publish()
        return true
    }

    /// Logout (or `AppRefer.reset()`): queued messages for the account stop on the server.
    /// Offline, or before `start()` in this process, the logout is saved and sent before
    /// anything else on the next start.
    func logout() async {
        await serially { await self.runLogout() }
    }

    private static let pendingLogoutAnyKey = "apprefer_engagement_pending_logout_any"

    private func runLogout() async {
        guard started, credential != nil else {
            // Not started yet in this process: whichever slot starts next logs out first.
            defaults.set(true, forKey: Self.pendingLogoutAnyKey)
            generation += 1
            return
        }
        // Saved with the identity it signs out of; a newer pending logout keeps the older epoch
        // only if nothing newer was confirmed in between.
        let expected = knownEpoch
        beginIdentityChange()
        if !pendingLogout || pendingLogoutEpoch == nil { pendingLogout = true; pendingLogoutEpoch = expected }
        guard case .active = status, let apiKey, let credential, let epoch = pendingLogoutEpoch else { return }
        let gen = generation
        let (code, body, _) = await send("POST", "/api/engagement/v1/installs/me/logout", body: ["expectedEpoch": epoch], apiKey: apiKey, credential: credential)
        guard gen == generation else { return }
        if code == 200 {
            pendingLogout = false
            accountEpoch = body?["accountEpoch"] as? Int
            lastSync = nil
            publish()
        } else if code == 409 {
            // Already signed out of that identity on the server (a newer one is there): done.
            pendingLogout = false
            _ = await reverify(gen: gen)
        } else {
            handleFailure(code, body)
        }
    }

    /// Forgets this install here and on the server (its preferences go with it).
    func deleteInstall() async {
        await serially { await self.runDelete() }
    }

    private func runDelete() async {
        guard let apiKey else { return }
        if credential == nil, case .found(let saved) = loadCredential() { credential = saved }
        guard var marked = credential else { return }
        beginIdentityChange()
        defaults.removeObject(forKey: key("epoch"))
        marked.pendingDelete = true
        credential = marked
        _ = saveCredential(marked, adding: false)
        _ = await sendDelete(apiKey: apiKey, gen: generation)
        status = credential == nil ? .notStarted : .pending
        started = false
        publish()
    }

    private func sendDelete(apiKey: String, gen: Int) async -> Bool {
        guard let credential else { return true }
        let (code, _, _) = await send("DELETE", "/api/engagement/v1/installs/me", body: nil, apiKey: apiKey, credential: credential)
        // 401: already gone on the server. 404 disabled: nothing there can be sent.
        guard code == 200 || code == 401 || code == 404 else { return false }
        keychain.delete(key: credentialKey())
        self.credential = nil
        accountEpoch = nil
        pendingLogout = false
        lastSync = nil
        return true
    }

    // MARK: Preferences

    func preferences() async throws -> AppReferEngagementPreferences {
        try await serially { await self.runPreferences() }.get()
    }

    private func runPreferences() async -> Result<AppReferEngagementPreferences, AppReferEngagementError> {
        guard case .active = status, let apiKey, let credential else { return .failure(.notStarted) }
        let gen = generation
        let (code, body, _) = await send("GET", "/api/engagement/v1/installs/me/preferences", body: nil, apiKey: apiKey, credential: credential)
        guard gen == generation else { return .failure(.identityChanged) }
        guard code == 200, let prefs = Self.preferences(body), let epoch = body?["accountEpoch"] as? Int else { handleFailure(code, body); return .failure(failure(code, body)) }
        // The choices are for the epoch they came with: learn it, so a later change is made for it.
        let before = serial
        observeEpoch(epoch)
        if before != serial { publish() }
        return .success(prefs)
    }

    func setPreferences(_ choices: [String: Bool]) async throws -> AppReferEngagementPreferences {
        try await serially { await self.runSetPreferences(choices) }.get()
    }

    private func runSetPreferences(_ choices: [String: Bool]) async -> Result<AppReferEngagementPreferences, AppReferEngagementError> {
        guard !choices.isEmpty else { return .failure(.server(status: 400, code: "INVALID_BODY")) }
        guard case .active = status, let apiKey, let credential else { return .failure(.notStarted) }
        // Only for the identity the person is using now: never mid sign-in or sign-out. The server
        // refuses it (409) if the install's identity is no longer this epoch.
        guard let epoch = accountEpoch else { return .failure(.identityChanged) }
        let gen = generation
        var body: [String: Any] = choices
        body["expectedEpoch"] = epoch
        let (code, json, _) = await send("PUT", "/api/engagement/v1/installs/me/preferences", body: body, apiKey: apiKey, credential: credential)
        guard gen == generation else { return .failure(.identityChanged) }
        if code == 409 { _ = await reverify(gen: gen); return .failure(.identityChanged) }
        guard code == 200, let prefs = Self.preferences(json) else { handleFailure(code, json); return .failure(failure(code, json)) }
        return .success(prefs)
    }

    private static func preferences(_ body: [String: Any]?) -> AppReferEngagementPreferences? {
        guard let purposes = body?["purposes"] as? [String: Any] else { return nil }
        func granted(_ name: String) -> Bool? { (purposes[name] as? [String: Any])?["granted"] as? Bool }
        guard let m = granted("marketing"), let r = granted("reminders"), let s = granted("service") else { return nil }
        return AppReferEngagementPreferences(marketing: m, reminders: r, service: s)
    }

    private static func code(_ body: [String: Any]?) -> String? { (body?["error"] as? [String: Any])?["code"] as? String }
    private func failure(_ code: Int?, _ body: [String: Any]?) -> AppReferEngagementError {
        guard let code else { return .unavailable }
        if code == 404, Self.code(body) == "ENGAGEMENT_DISABLED" { return .disabled }
        if code == 409 { return .identityChanged }
        if code >= 500 || code == 429 { return .unavailable }
        return .server(status: code, code: Self.code(body))
    }

    // MARK: Receipts

    private static let receiptsKey = "apprefer_engagement_receipts"
    private func loadReceipts() -> [PendingEngagementReceipt] {
        guard let data = defaults.data(forKey: Self.receiptsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingEngagementReceipt].self, from: data)) ?? []
    }
    private func saveReceipts(_ items: [PendingEngagementReceipt]) {
        let fresh = items.filter { now().timeIntervalSince($0.occurredAt) < 7 * 86_400 && $0.attempts < 10 }
        defaults.set(try? JSONEncoder().encode(Array(fresh.suffix(100))), forKey: Self.receiptsKey)
    }
    private func dropReceipts(where predicate: (PendingEngagementReceipt) -> Bool) {
        saveReceipts(loadReceipts().filter { !predicate($0) })
    }

    /// Queues a receipt for a payload that matched this install and epoch when it arrived.
    func queueReceipt(kind: String, payload: AppReferEngagementPayload, actionId: String?, at date: Date) async {
        guard let snap = snapshot.get(), snap.installId == payload.installId, snap.accountEpoch == payload.accountEpoch else { return }
        var items = loadReceipts()
        guard !items.contains(where: { $0.messageId == payload.messageId && $0.kind == kind }) else { return }
        items.append(PendingEngagementReceipt(slot: snap.slot, installId: snap.installId, accountEpoch: payload.accountEpoch, serial: snap.serial,
                                              messageId: payload.messageId, token: payload.receiptToken, kind: kind, actionId: actionId,
                                              occurredAt: date, attempts: 0))
        saveReceipts(items)
        await serially { await self.flushReceipts() }
    }

    var pendingReceiptCount: Int { loadReceipts().count }

    private func flushReceipts() async {
        guard case .active = status, let apiKey, let credential, let slot, let epoch = accountEpoch else { return }
        // Markers the Notification Service Extension left, for this identity only.
        if let shared = sharedState {
            for marker in shared.takeReceived() where marker.installId == credential.installId && marker.accountEpoch == epoch {
                var items = loadReceipts()
                if !items.contains(where: { $0.messageId == marker.messageId && $0.kind == "received" }) {
                    items.append(PendingEngagementReceipt(slot: slot, installId: marker.installId, accountEpoch: epoch, serial: serial,
                                                          messageId: marker.messageId, token: marker.receiptToken, kind: "received",
                                                          actionId: nil, occurredAt: marker.receivedAt, attempts: 0))
                    saveReceipts(items)
                }
            }
        }
        let gen = generation
        let currentSerial = serial
        // Receipts of an earlier identity are never sent under the current one.
        dropReceipts { $0.slot == slot && ($0.installId != credential.installId || $0.accountEpoch != epoch || $0.serial != currentSerial) }
        let batch = Array(loadReceipts().filter { $0.slot == slot }.prefix(20))
        guard !batch.isEmpty else { return }
        let items: [[String: Any]] = batch.map { r in
            var item: [String: Any] = ["messageId": r.messageId, "token": r.token, "kind": r.kind, "occurredAt": Int(r.occurredAt.timeIntervalSince1970 * 1000)]
            if let actionId = r.actionId { item["actionId"] = actionId }
            return item
        }
        let (code, body, _) = await send("POST", "/api/engagement/v1/installs/me/receipts", body: ["receipts": items], apiKey: apiKey, credential: credential)
        guard gen == generation else { return }
        var remaining = loadReceipts()
        if code == 200, let results = body?["results"] as? [[String: Any]] {
            // Every answered item is final (accepted, duplicate or rejected).
            for (index, sent) in batch.enumerated() where index < results.count {
                remaining.removeAll { $0.messageId == sent.messageId && $0.kind == sent.kind && $0.slot == sent.slot }
            }
            saveReceipts(remaining)
            if batch.count == 20 { await flushReceipts() }
        } else if code == 400 {
            remaining.removeAll { r in batch.contains { $0.messageId == r.messageId && $0.kind == r.kind } }
            saveReceipts(remaining)
        } else if !handleFailure(code, body) {
            for i in remaining.indices where batch.contains(where: { $0.messageId == remaining[i].messageId && $0.kind == remaining[i].kind }) {
                remaining[i].attempts += 1
            }
            saveReceipts(remaining)
        }
    }

    // MARK: Reset hooks

    /// `AppRefer.reset()`: the account is gone from this device.
    func accountReset() async { await logout() }

    var isStarted: Bool { started }

    func stateForTesting() -> (status: AppReferEngagementStatus, epoch: Int?, serial: Int, pendingLogout: Bool) {
        (status, accountEpoch, serial, pendingLogout)
    }

    // MARK: HTTP

    private func send(_ method: String, _ path: String, body: [String: Any]?, apiKey: String, credential: Credential?) async -> (Int?, [String: Any]?, Data?) {
        guard let url = URL(string: baseURL + path) else { return (nil, nil, nil) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-AppRefer-Key")
        request.setValue(AppReferVersion.current, forHTTPHeaderField: "X-SDK-Version")
        if let credential { request.setValue("\(credential.installId).\(credential.secret)", forHTTPHeaderField: "X-AppRefer-Install") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return ((response as? HTTPURLResponse)?.statusCode, json, data)
        } catch {
            return (nil, nil, nil)
        }
    }
}
