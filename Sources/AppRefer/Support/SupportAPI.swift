import Foundation
/// Customer side of AppRefer Support over the SDK key. The support session
/// token is minted on first use and kept in the Keychain; only its hash is
/// stored on the server.
private final class SupportGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value += 1 }
}

actor SupportAPI {
    static let shared: SupportAPI = {
        let api = SupportAPI()
        Task { await api.retryRevocations() }
        return api
    }()

    private static let tokenKey = "apprefer_support_session"
    private static let profileKey = "apprefer_support_profile"
    /// Set when the stored session was minted (or adopted) while the identity was cleared.
    /// Such a session is never handed to an account stored later; it is retired instead.
    /// Kept in the Keychain next to the session token, so it survives a reinstall with it
    /// (0.9.2 kept it in UserDefaults; that copy is moved on first read).
    static let clearedSessionKey = "apprefer_support_session_cleared"
    private static let pushKey = "apprefer_support_push_token"
    private let session: URLSession
    private let baseURL: String
    private var token: String?
    private var name: String?
    private var email: String?
    private var supportApiKey: String?
    private nonisolated let accountGeneration = SupportGeneration()
    nonisolated var actionGeneration: Int { accountGeneration.read() }
    private var generation: Int { actionGeneration }
    private struct Revocation: Codable, Equatable {
        let token: String; let push: String?; let key: String?
        var createdAt: Double? = nil
        var attempts: Int? = nil
        /// Register `push` on the current session once this one is revoked (clearIdentity,
        /// or the app registering the same token again), so the two sessions never hold the
        /// same token at once.
        var move: Bool? = nil
        /// The push environment the app last registered `push` with (nil: the build's).
        var sandbox: Bool? = nil
    }
    private let revocationKey = "apprefer_support_revocations"

    /// Functional Support startup: deliberately never constructs an attribution SDK.
    func configure(apiKey: String) {
        supportApiKey = apiKey
        UserDefaults.standard.set(apiKey, forKey: "apprefer_support_last_key")
        Task { await revokePending(using: apiKey) }
    }

    func resumeRevocations(apiKey: String) {
        let key = supportApiKey ?? apiKey
        Task { await revokePending(using: key) }
    }

    /// The running revocation pass, if any. A request that arrives while it runs is not
    /// dropped: the pass runs again once it finishes (until no new request came in).
    private var revocationRun: Task<Void, Never>?
    private var revokeAgain = false
    private var revokeKey: String?
    private var deferredRevocations: [Revocation] = []
    private func savedRevocations() -> [Revocation] {
        let stored = KeychainHelper.load(key: revocationKey).value?.data(using: .utf8).flatMap { try? JSONDecoder().decode([Revocation].self, from: $0) } ?? []
        return deferredRevocations.reduce(into: stored) { result, item in
            if !result.contains(where: { $0.token == item.token && $0.key == item.key }) { result.append(item) }
        }
    }
    private func saveRevocations(_ items: [Revocation]) {
        deferredRevocations = items
        switch KeychainHelper.load(key: revocationKey) {
        case .found(let raw):
            if let data = raw.data(using: .utf8), let saved = try? JSONDecoder().decode([Revocation].self, from: data), saved == items { return }
        case .notFound: if items.isEmpty { return }
        case .unavailable, .failed: return // Never overwrite unreadable saved work.
        }
        if let data = try? JSONEncoder().encode(items) {
            _ = KeychainHelper.save(key: revocationKey, value: String(decoding: data, as: UTF8.self))
        }
    }
    /// Runs a revocation pass. Called while one is running, it asks for one more pass after
    /// it and waits for both, so a revocation queued meanwhile (clearIdentity, a retired
    /// cleared session) is processed in this app session, not at the next foreground.
    func revokePending(using key: String) async {
        revokeKey = key
        if let running = revocationRun {
            revokeAgain = true
            await running.value
            return
        }
        let run = Task { await self.runRevocationPasses() }
        revocationRun = run
        await run.value
    }

    private func runRevocationPasses() async {
        repeat {
            revokeAgain = false
            await revocationPass(using: revokeKey ?? "")
        } while revokeAgain
        revocationRun = nil
    }

    private func revocationPass(using key: String) async {
        let pending = savedRevocations()
        for original in pending {
            var item = original
            item.createdAt = item.createdAt ?? Date().timeIntervalSince1970
            item.attempts = item.attempts ?? 0
            let expired = Date().timeIntervalSince1970 - item.createdAt! > 400 * 86_400
            var remove = expired || item.attempts! >= 20
            var revoked = false
            if !remove {
                revoked = await revoke(item, using: item.key ?? key)
                remove = revoked
                if !remove { item.attempts! += 1; remove = item.attempts! >= 20 }
            }
            var current = savedRevocations()
            if let index = current.firstIndex(where: { $0.token == item.token && $0.key == item.key }) {
                // The saved entry may have been marked to move meanwhile (registerPushToken).
                let latest = current[index]
                item.move = latest.move
                item.sandbox = latest.sandbox
                if remove { current.remove(at: index) } else { current[index] = item }
                saveRevocations(current)
            }
            // The old session is gone: move its push token to the current session, unless a
            // reset has removed the token since (it never moves to the next account unless
            // the app registers it again).
            if revoked, item.move == true, let push = item.push,
               UserDefaults.standard.string(forKey: Self.pushKey) == push {
                try? await registerPushToken(push, sandbox: item.sandbox ?? Self.pushSandbox)
            }
        }
    }
    private func revoke(_ item: Revocation, using key: String) async -> Bool {
        guard let url = URL(string: baseURL + "/api/support/v1/session") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "X-AppRefer-Key")
        request.setValue(item.token, forHTTPHeaderField: "X-AppRefer-Support-Session")
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status) || [401, 403, 404].contains(status)
        } catch { return false }
    }

    func reset() async {
        retireSession(keepPushToken: false)
        // Local cleanup completes before any network work starts.
    }

    /// When a session waiting for its revocation still holds `push` (whether or not it was
    /// marked to move, e.g. after reset() or from an older version), marks it to move with
    /// the environment now known and returns true: the revocation pass registers the token
    /// on the current session once the old one is revoked, never before.
    private func deferPushToPendingRevocation(_ push: String, sandbox: Bool) -> Bool {
        var pending = savedRevocations()
        var held = false
        for index in pending.indices where pending[index].push == push {
            pending[index].move = true
            pending[index].sandbox = sandbox
            held = true
        }
        if held { saveRevocations(pending) }
        return held
    }

    /// Removes the account from Support without a full reset (consent withdrawn): forgets
    /// the name, email and app user id, revokes the current session through the durable
    /// revocation list and starts a new anonymous one with no link to the old id. The old
    /// session's conversations stay in the team inbox but are no longer shown in the app.
    /// The app user id stays off Support until it changes or reset() runs.
    func clearIdentity() async {
        userStorage.supportIdentityCleared = true
        // The push token stays stored and moves to the new session once the old one is
        // revoked (revokePending), never before.
        retireSession(keepPushToken: true)
        guard supportApiKey ?? AppRefer.currentApiKey() != nil else { return }
        // Mint the anonymous replacement now.
        _ = try? await sessionToken()
    }

    /// Forgets the session locally and queues its revocation. With `keepPushToken` the
    /// token stays stored and is moved to the next session after the revocation succeeds.
    private func retireSession(keepPushToken: Bool) {
        accountGeneration.advance()
        minting?.cancel()
        minting = nil
        name = nil
        email = nil
        persona = nil
        retireToken(keepPushToken: keepPushToken)
    }

    /// Drops the stored session (token, cleared marker, profile fingerprint) and queues its
    /// durable revocation, without touching the account generation or the profile.
    private func retireToken(keepPushToken: Bool) {
        let oldToken = token ?? KeychainHelper.load(key: Self.tokenKey).value
        let key = supportApiKey ?? AppRefer.currentApiKey() ?? UserDefaults.standard.string(forKey: "apprefer_support_last_key")
        let pushToken = UserDefaults.standard.string(forKey: Self.pushKey)
        if !keepPushToken { UserDefaults.standard.removeObject(forKey: Self.pushKey) }
        dropToken()
        if let oldToken {
            var pending = savedRevocations()
            pending.append(Revocation(token: oldToken, push: pushToken, key: key, createdAt: Date().timeIntervalSince1970, attempts: 0,
                                      move: keepPushToken && pushToken != nil ? true : nil))
            saveRevocations(pending)
        }
    }

    private func dropToken() {
        token = nil
        KeychainHelper.delete(key: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        Self.setSessionMintedWhileCleared(false)
    }

    /// Whether the stored session was minted while the identity was cleared. Read from the
    /// Keychain; a 0.9.2 UserDefaults copy is moved there (and kept if the move fails).
    static func sessionMintedWhileCleared() -> Bool {
        if case .found = KeychainHelper.load(key: clearedSessionKey) { return true }
        guard UserDefaults.standard.bool(forKey: clearedSessionKey) else { return false }
        if KeychainHelper.save(key: clearedSessionKey, value: "1") {
            UserDefaults.standard.removeObject(forKey: clearedSessionKey)
        }
        return true
    }

    /// Kept next to the session token in the Keychain; UserDefaults only if that fails.
    static func setSessionMintedWhileCleared(_ cleared: Bool) {
        if cleared {
            if KeychainHelper.save(key: clearedSessionKey, value: "1") { UserDefaults.standard.removeObject(forKey: clearedSessionKey) }
            else { UserDefaults.standard.set(true, forKey: clearedSessionKey) }
        } else {
            KeychainHelper.delete(key: clearedSessionKey)
            UserDefaults.standard.removeObject(forKey: clearedSessionKey)
        }
    }

    /// A session minted while the identity was cleared is never handed to an account stored
    /// later (a different user id turns the clear off without a reset): it is revoked, its
    /// push token moves once that succeeds, and the caller mints a fresh session.
    /// In-flight calls are not cancelled.
    private func retireClearedSessionIfNeeded() -> Bool {
        guard !userStorage.supportIdentityCleared, Self.sessionMintedWhileCleared() else { return false }
        minting = nil
        retireToken(keepPushToken: true)
        Task { await self.retryRevocations() }
        return true
    }

    #if DEBUG
    static let pushSandbox = true
    #else
    static let pushSandbox = false
    #endif

    func retryRevocations() {
        guard let key = supportApiKey ?? AppRefer.currentApiKey() ?? UserDefaults.standard.string(forKey: "apprefer_support_last_key") else { return }
        Task { await revokePending(using: key) }
    }

    /// The install device id to link, or nil (Support-only, after reset, collection off).
    private let deviceId: @Sendable () -> String?
    /// Where the app user id (and the identity-cleared flag) are kept.
    private let userStorage: AppReferStorage

    init(baseURL: String = AppReferConfig.backendURL, session: URLSession = URLSession(configuration: .default),
         deviceId: @escaping @Sendable () -> String? = { AppRefer.supportDeviceId() },
         userStorage: AppReferStorage = AppReferStorage()) {
        self.baseURL = baseURL
        self.session = session
        self.deviceId = deviceId
        self.userStorage = userStorage
    }

    func setIdentity(name: String?, email: String?, generation expected: Int? = nil) {
        guard expected == nil || expected == generation else { return }
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.email = email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var displayName: String? { name }

    /// The app's AI assistant, from the latest list or conversation read (nil when the app has none).
    private(set) var persona: AppReferSupportPersona?

    // MARK: - Session

    private var profile: [String: Any] {
        var body: [String: Any] = [:]
        // After clearIdentity(): neither the app user id nor the install id (which would
        // link the anonymous session straight back to the account).
        if !userStorage.supportIdentityCleared {
            if let id = userStorage.getUserId() { body["appUserId"] = id }
            if let device = deviceId() { body["deviceId"] = device }
        }
        if let name { body["name"] = name }
        if let email { body["email"] = email }
        return body
    }

    private var minting: Task<String, Error>?

    /// The session token, minted on first use. Concurrent first calls share one
    /// mint, so the app never ends up with two sessions. The profile (app user
    /// id, name, email) is re-sent only when it changes, and recorded as synced
    /// only once the server has it.
    private func sessionToken() async throws -> String {
        _ = retireClearedSessionIfNeeded()
        let epoch = generation
        if token == nil { token = KeychainHelper.load(key: Self.tokenKey).value }
        let cleared = userStorage.supportIdentityCleared
        let current = profile
        let profileJSON = (try? JSONSerialization.data(withJSONObject: current, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        if let token {
            if UserDefaults.standard.string(forKey: Self.profileKey) != profileJSON {
                let data = try await raw("POST", "/api/support/v1/session", body: current, session: token, expectedGeneration: epoch)
                let refreshed = try JSONDecoder().decode(SupportSession.self, from: data)
                // The server may hand back a replacement session.
                if refreshed.session != token { adopt(refreshed.session, cleared: cleared) }
                UserDefaults.standard.set(profileJSON, forKey: Self.profileKey)
            }
            return self.token ?? token
        }
        if let minting, mintingCleared == cleared { return try await minting.value }
        let task = Task { () throws -> String in
            let data = try await self.raw("POST", "/api/support/v1/session", body: current, session: nil, expectedGeneration: epoch)
            return try JSONDecoder().decode(SupportSession.self, from: data).session
        }
        minting = task
        mintingCleared = cleared
        defer { if epoch == generation, minting == task { minting = nil } }
        let minted = try await task.value
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        adopt(minted, cleared: cleared)
        UserDefaults.standard.set(profileJSON, forKey: Self.profileKey)
        // Minted for a cleared identity that was turned off meanwhile: never use it.
        if retireClearedSessionIfNeeded() { return try await sessionToken() }
        return minted
    }

    private var mintingCleared = false

    private func adopt(_ session: String, cleared: Bool) {
        _ = KeychainHelper.save(key: Self.tokenKey, value: session)
        token = session
        Self.setSessionMintedWhileCleared(cleared)
    }

    // MARK: - HTTP

    private func raw(_ method: String, _ path: String, body: [String: Any]?, session sessionToken: String?, expectedGeneration: Int? = nil) async throws -> Data {
        let epoch = expectedGeneration ?? generation
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        guard let apiKey = supportApiKey ?? AppRefer.currentApiKey(), let url = URL(string: baseURL + path) else {
            throw AppReferSupportError(status: 0, message: "AppRefer isn't configured")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-AppRefer-Key")
        if let sessionToken { req.setValue(sessionToken, forHTTPHeaderField: "X-AppRefer-Support-Session") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AppReferSupportError(status: status, message: message ?? "Something went wrong (\(status))")
        }
        return data
    }

    /// A request with the session; a session the server no longer knows is replaced once.
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil, expectedGeneration: Int? = nil) async throws -> Data {
        let epoch = expectedGeneration ?? generation
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        do {
            let bearer = try await sessionToken()
            guard epoch == generation else { throw CancellationError() }
            return try await raw(method, path, body: body, session: bearer, expectedGeneration: epoch)
        } catch let error as AppReferSupportError where error.status == 401 && error.message.contains("support session") {
            guard epoch == generation else { throw CancellationError() }
            dropToken()
            return try await raw(method, path, body: body, session: try await sessionToken(), expectedGeneration: epoch)
        }
    }

    // MARK: - Endpoints

    func conversations() async throws -> [AppReferSupportConversation] {
        let list = try JSONDecoder().decode(SupportConversationList.self, from: try await call("GET", "/api/support/v1/conversations"))
        persona = list.persona
        return list.conversations
    }

    func start(text: String, subject: String? = nil, attachmentIds: [String], clientMessageId: String, generation epoch: Int? = nil) async throws -> SupportThread {
        var body: [String: Any] = ["text": text, "context": Self.context(), "clientMessageId": clientMessageId]
        if let subject { body["subject"] = subject }
        if !attachmentIds.isEmpty { body["attachmentIds"] = attachmentIds }
        return try JSONDecoder().decode(SupportThread.self, from: try await call("POST", "/api/support/v1/conversations", body: body, expectedGeneration: epoch))
    }

    func thread(_ id: String, after: String?) async throws -> SupportThread {
        var path = "/api/support/v1/conversations/\(id.urlPathEscaped)"
        if let after, let q = after.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) { path += "?after=\(q)" }
        let thread = try JSONDecoder().decode(SupportThread.self, from: try await call("GET", path))
        persona = thread.persona
        return thread
    }

    /// `clientMessageId` stays the same on retries, so a retry never duplicates.
    func send(_ id: String, text: String, attachmentIds: [String], clientMessageId: String, generation epoch: Int? = nil) async throws -> AppReferSupportMessage {
        var body: [String: Any] = ["text": text, "clientMessageId": clientMessageId]
        if !attachmentIds.isEmpty { body["attachmentIds"] = attachmentIds }
        let data = try await call("POST", "/api/support/v1/conversations/\(id.urlPathEscaped)/messages", body: body, expectedGeneration: epoch)
        return try JSONDecoder().decode(SupportSent.self, from: data).message
    }

    /// Uploads one compressed image straight to storage and returns its attachment id.
    func upload(_ jpeg: Data, name: String = "screenshot.jpg", generation expected: Int? = nil) async throws -> String {
        let epoch = expected ?? generation
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        let slotData = try await call("POST", "/api/support/v1/attachments", body: ["contentType": "image/jpeg", "size": jpeg.count, "name": name], expectedGeneration: epoch)
        let slot = try JSONDecoder().decode(SupportUploadSlot.self, from: slotData)
        guard let url = URL(string: slot.uploadUrl) else { throw AppReferSupportError(status: 0, message: "Bad upload address") }
        var put = URLRequest(url: url, timeoutInterval: 60)
        put.httpMethod = "PUT"
        for (k, v) in slot.headers { put.setValue(v, forHTTPHeaderField: k) }
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        let (_, response) = try await session.upload(for: put, from: jpeg)
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AppReferSupportError(status: status, message: "The screenshot didn't upload (\(status))") }
        return slot.attachmentId
    }

    func registerPushToken(_ hex: String, sandbox: Bool, generation expected: Int? = nil) async throws {
        let epoch = expected ?? generation
        guard epoch == generation else { throw CancellationError() }
        // Still on a session whose revocation hasn't been confirmed: it moves once that
        // succeeds, so the two sessions never hold it at the same time.
        if deferPushToPendingRevocation(hex, sandbox: sandbox) {
            UserDefaults.standard.set(hex, forKey: Self.pushKey)
            retryRevocations()
            return
        }
        _ = try await call("POST", "/api/support/v1/push-token", body: ["platform": "ios", "token": hex, "environment": sandbox ? "sandbox" : "production"], expectedGeneration: epoch)
        UserDefaults.standard.set(hex, forKey: Self.pushKey)
    }

    func removePushToken(_ hex: String) async throws {
        _ = try await call("DELETE", "/api/support/v1/push-token", body: ["token": hex])
        UserDefaults.standard.removeObject(forKey: Self.pushKey)
    }

    // MARK: - Context

    /// App version, device and OS, shown to the team with a new conversation.
    static func context() -> [String: Any] {
        var c: [String: Any] = ["platform": "ios", "locale": Locale.current.identifier]
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { c["appVersion"] = v }
        // The simulator reports its CPU ("arm64"); it names the simulated model separately.
        c["device"] = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? AppReferDeviceInfo.collect()["model"] as? String ?? "unknown"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        c["os"] = "iOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
        return c
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var urlPathEscaped: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?")
        return set
    }()
}
