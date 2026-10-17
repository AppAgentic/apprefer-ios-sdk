import Foundation
@testable import AppRefer

/// In-memory stand-in for AppRefer's engagement routes (the contract in
/// web/lib/engagement), reached through URLProtocol. Records every request.
final class FakeEngagementServer: @unchecked Sendable {
    struct Install { var secret: String; var key: String; var epoch = 0; var account: String?; var prefs = ["marketing": false, "reminders": false, "service": true]; var patches: [[String: Any]] = [] }
    struct Logged { let method: String; let path: String; let headers: [String: String]; let body: [String: Any] }

    private let lock = NSLock()
    private var installs: [String: Install] = [:]
    private(set) var log: [Logged] = []
    var disabled = false
    var offline = false
    /// Seconds to hold a response, by "METHOD path".
    var delays: [String: TimeInterval] = [:]
    var receiptResults: (([String: Any]) -> String)?
    private var counter = 0

    static var current: FakeEngagementServer?

    func session() -> URLSession {
        FakeEngagementServer.current = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EngagementStub.self]
        return URLSession(configuration: config)
    }

    func requests(_ method: String? = nil, _ path: String? = nil) -> [Logged] {
        lock.lock(); defer { lock.unlock() }
        return log.filter { (method == nil || $0.method == method) && (path == nil || $0.path == path) }
    }
    func install(_ id: String) -> Install? { lock.lock(); defer { lock.unlock() }; return installs[id] }
    var installCount: Int { lock.lock(); defer { lock.unlock() }; return installs.count }
    func set(_ id: String, _ update: (inout Install) -> Void) { lock.lock(); if var i = installs[id] { update(&i); installs[id] = i }; lock.unlock() }
    func forget(_ id: String) { lock.lock(); installs[id] = nil; lock.unlock() }
    /// The app's backend binds (or, with nil, detaches) the install directly: the epoch moves
    /// without the SDK being told.
    func backendBind(_ id: String, to account: String?) {
        set(id) { $0.account = account; $0.epoch += 1; $0.prefs = ["marketing": false, "reminders": false, "service": $0.prefs["service"] == false ? false : true] }
    }

    func handle(_ request: URLRequest, body: [String: Any]) -> (Int, [String: Any])? {
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        lock.lock()
        log.append(Logged(method: method, path: path, headers: headers, body: body))
        defer { lock.unlock() }
        if offline { return nil }
        if disabled { return (404, ["error": ["code": "ENGAGEMENT_DISABLED", "message": "off"]]) }
        let key = headers["X-AppRefer-Key"] ?? ""
        if path == "/api/engagement/v1/installs", method == "POST" {
            counter += 1
            let id = "ei_" + String(String(repeating: "a", count: 25) + "\(counter % 6 + 2)").suffix(26)
            let secret = "eis_" + String(repeating: "S", count: 42) + "\(counter % 10)"
            installs[id] = Install(secret: secret, key: key)
            return (201, ["installId": id, "installSecret": secret, "environment": "live"])
        }
        guard let cred = headers["X-AppRefer-Install"], let dot = cred.firstIndex(of: "."),
              var install = installs[String(cred[..<dot])], install.secret == String(cred[cred.index(after: dot)...]), install.key == key else {
            return (401, ["error": ["code": "INVALID_INSTALL", "message": "bad"]])
        }
        let id = String(cred[..<dot])
        func me() -> [String: Any] { ["install": ["installId": id, "accountEpoch": install.epoch, "accountBound": install.account != nil]] }
        func prefs() -> [String: Any] { ["purposes": install.prefs.mapValues { ["granted": $0] }, "revision": 1, "accountEpoch": install.epoch] }
        // Identity mutations must state the epoch they were made under (web/lib/engagement/identity.ts).
        let identityMutation = (method == "PUT" && path.hasSuffix("/preferences")) || (method == "POST" && (path.hasSuffix("/logout") || path.hasSuffix("/account")))
        let expected = (body["expectedEpoch"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue }
        if identityMutation, expected == nil { return (400, ["error": ["code": "INVALID_BODY", "message": "expectedEpoch is required"]]) }
        let stale = (409, ["error": ["code": "IDENTITY_CHANGED", "message": "changed"]] as [String: Any])
        switch (method, path) {
        case ("GET", "/api/engagement/v1/installs/me"): return (200, me())
        case ("PATCH", "/api/engagement/v1/installs/me"):
            install.patches.append(body); installs[id] = install
            return (200, me())
        case ("DELETE", "/api/engagement/v1/installs/me"):
            installs[id] = nil
            return (200, ["deleted": true])
        case ("POST", "/api/engagement/v1/installs/me/account"):
            guard let assertion = body["assertion"] as? String, assertion.hasPrefix("ok:") else {
                return (401, ["error": ["code": "INVALID_ASSERTION", "message": "bad"]])
            }
            let user = String(assertion.dropFirst(3))
            if install.account != user, expected != install.epoch { return stale }
            if install.account != user {
                install.account = user; install.epoch += 1
                install.prefs = ["marketing": false, "reminders": false, "service": install.prefs["service"] == false ? false : true]
            }
            installs[id] = install
            return (200, ["accountEpoch": install.epoch, "changed": true])
        case ("POST", "/api/engagement/v1/installs/me/logout"):
            if expected != install.epoch { return stale }
            install.account = nil; install.epoch += 1
            install.prefs = ["marketing": false, "reminders": false, "service": install.prefs["service"] == false ? false : true]
            installs[id] = install
            return (200, ["accountEpoch": install.epoch])
        case ("GET", "/api/engagement/v1/installs/me/preferences"): return (200, prefs())
        case ("PUT", "/api/engagement/v1/installs/me/preferences"):
            if expected != install.epoch { return stale }
            for (k, v) in body where k != "expectedEpoch" { if let b = v as? Bool { install.prefs[k] = b } }
            installs[id] = install
            return (200, prefs())
        case ("POST", "/api/engagement/v1/installs/me/receipts"):
            let items = body["receipts"] as? [[String: Any]] ?? []
            return (200, ["results": items.map { ["messageId": $0["messageId"] ?? "", "kind": $0["kind"] ?? "", "status": receiptResults?($0) ?? "accepted"] }])
        default: return (404, ["error": ["code": "NOT_FOUND"]])
        }
    }
}

final class EngagementStub: URLProtocol, @unchecked Sendable {
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = FakeEngagementServer.current else { return }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let delay = server.delays["\(request.httpMethod ?? "GET") \(request.url!.path)"] ?? 0
        let request = self.request
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard !cancelled else { return }
            guard let (status, json) = server.handle(request, body: body) else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { cancelled = true }
}
