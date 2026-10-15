import Foundation
/// Customer side of AppRefer Support over the SDK key. The support session
/// token is minted on first use and kept in the Keychain; only its hash is
/// stored on the server.
actor SupportAPI {
    static let shared = SupportAPI()

    private static let tokenKey = "apprefer_support_session"
    private static let profileKey = "apprefer_support_profile"
    private let session: URLSession
    private let baseURL: String
    private var token: String?
    private var name: String?
    private var email: String?

    init(baseURL: String = AppReferConfig.backendURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func setIdentity(name: String?, email: String?) {
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.email = email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var displayName: String? { name }

    // MARK: - Session

    private var profile: [String: Any] {
        let storage = AppReferStorage()
        var body: [String: Any] = [:]
        if let id = storage.getUserId() { body["appUserId"] = id }
        if let device = storage.deviceId() { body["deviceId"] = device }
        if let name { body["name"] = name }
        if let email { body["email"] = email }
        return body
    }

    /// The session token, minted on first use. The profile (app user id, name,
    /// email) is re-sent only when it changes.
    private func sessionToken() async throws -> String {
        if token == nil { token = KeychainHelper.load(key: Self.tokenKey).value }
        let profileJSON = (try? JSONSerialization.data(withJSONObject: profile, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        if let token {
            if UserDefaults.standard.string(forKey: Self.profileKey) != profileJSON {
                _ = try? await raw("POST", "/api/support/v1/session", body: profile, session: token)
                UserDefaults.standard.set(profileJSON, forKey: Self.profileKey)
            }
            return token
        }
        let data = try await raw("POST", "/api/support/v1/session", body: profile, session: nil)
        let minted = try JSONDecoder().decode(SupportSession.self, from: data).session
        _ = KeychainHelper.save(key: Self.tokenKey, value: minted)
        UserDefaults.standard.set(profileJSON, forKey: Self.profileKey)
        token = minted
        return minted
    }

    // MARK: - HTTP

    private func raw(_ method: String, _ path: String, body: [String: Any]?, session sessionToken: String?) async throws -> Data {
        guard let apiKey = AppRefer.currentApiKey(), let url = URL(string: baseURL + path) else {
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AppReferSupportError(status: status, message: message ?? "Something went wrong (\(status))")
        }
        return data
    }

    /// A request with the session; a session the server no longer knows is replaced once.
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        do {
            return try await raw(method, path, body: body, session: try await sessionToken())
        } catch let error as AppReferSupportError where error.status == 401 && error.message.contains("support session") {
            KeychainHelper.delete(key: Self.tokenKey)
            token = nil
            return try await raw(method, path, body: body, session: try await sessionToken())
        }
    }

    // MARK: - Endpoints

    func conversations() async throws -> [AppReferSupportConversation] {
        try JSONDecoder().decode(SupportConversationList.self, from: try await call("GET", "/api/support/v1/conversations")).conversations
    }

    func start(text: String, attachmentIds: [String]) async throws -> SupportThread {
        var body: [String: Any] = ["text": text, "context": Self.context()]
        if !attachmentIds.isEmpty { body["attachmentIds"] = attachmentIds }
        return try JSONDecoder().decode(SupportThread.self, from: try await call("POST", "/api/support/v1/conversations", body: body))
    }

    func thread(_ id: String, after: String?) async throws -> SupportThread {
        var path = "/api/support/v1/conversations/\(id.urlPathEscaped)"
        if let after, let q = after.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) { path += "?after=\(q)" }
        return try JSONDecoder().decode(SupportThread.self, from: try await call("GET", path))
    }

    func send(_ id: String, text: String, attachmentIds: [String]) async throws -> AppReferSupportMessage {
        var body: [String: Any] = ["text": text]
        if !attachmentIds.isEmpty { body["attachmentIds"] = attachmentIds }
        let data = try await call("POST", "/api/support/v1/conversations/\(id.urlPathEscaped)/messages", body: body)
        return try JSONDecoder().decode(SupportSent.self, from: data).message
    }

    /// Uploads one compressed image straight to storage and returns its attachment id.
    func upload(_ jpeg: Data, name: String = "screenshot.jpg") async throws -> String {
        let slotData = try await call("POST", "/api/support/v1/attachments", body: ["contentType": "image/jpeg", "size": jpeg.count, "name": name])
        let slot = try JSONDecoder().decode(SupportUploadSlot.self, from: slotData)
        guard let url = URL(string: slot.uploadUrl) else { throw AppReferSupportError(status: 0, message: "Bad upload address") }
        var put = URLRequest(url: url, timeoutInterval: 60)
        put.httpMethod = "PUT"
        for (k, v) in slot.headers { put.setValue(v, forHTTPHeaderField: k) }
        let (_, response) = try await session.upload(for: put, from: jpeg)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AppReferSupportError(status: status, message: "The screenshot didn't upload (\(status))") }
        return slot.attachmentId
    }

    func registerPushToken(_ hex: String, sandbox: Bool) async throws {
        _ = try await call("POST", "/api/support/v1/push-token", body: ["platform": "ios", "token": hex, "environment": sandbox ? "sandbox" : "production"])
    }

    func removePushToken(_ hex: String) async throws {
        _ = try await call("DELETE", "/api/support/v1/push-token", body: ["token": hex])
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
