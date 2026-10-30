import Foundation

/// Errors thrown by AppReferBilling.
public enum AppReferBillingError: Error, LocalizedError, Sendable, Equatable {
    /// `AppReferBilling.configure()` has not been called.
    case notConfigured
    /// No SDK key: pass `apiKey:` to `AppReferBilling.configure` or call `AppRefer.configure` first.
    case missingApiKey
    /// AppRefer could not be reached.
    case network(String)
    /// AppRefer answered with an error status. `retryAfter` is the server's `Retry-After`, in seconds.
    case server(status: Int, message: String?, retryAfter: TimeInterval? = nil)
    /// AppRefer answered 2xx with a body the SDK could not read.
    case invalidResponse
    /// StoreKit could not verify the transaction's signature; no access was granted.
    case unverifiedTransaction
    /// App user ids must be 1-256 characters with no whitespace.
    case invalidAppUserId
    /// Billing identity or state could not be read or saved on this device.
    case storage(String)
    /// Who is buying couldn't be saved on the device, so the purchase sheet wasn't opened.
    case purchaseIntentNotSaved

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "AppReferBilling.configure() has not been called"
        case .missingApiKey: return "AppRefer SDK key missing: call AppRefer.configure(apiKey:) or pass apiKey to AppReferBilling.configure"
        case .network(let detail): return "AppRefer unreachable: \(detail)"
        case .server(let status, let message, _): return "AppRefer error \(status)\(message.map { ": \($0)" } ?? "")"
        case .invalidResponse: return "AppRefer returned an unreadable response"
        case .unverifiedTransaction: return "StoreKit could not verify the transaction"
        case .invalidAppUserId: return "Invalid app user id"
        case .storage(let message): return message
        case .purchaseIntentNotSaved: return "Couldn't save the purchase on this device; the purchase wasn't started"
        }
    }

    /// Whether the same request may succeed later. Only malformed requests (400/413/422)
    /// and local verification failures are final.
    var isRetryable: Bool {
        switch self {
        case .notConfigured, .missingApiKey, .network, .invalidResponse, .storage, .purchaseIntentNotSaved: return true
        case .server(let status, _, _): return ![400, 413, 422].contains(status)
        case .unverifiedTransaction, .invalidAppUserId: return false
        }
    }

    /// Statuses that mean "not now" rather than "never" (auth/config not set up yet, rate
    /// limited): the retry queue backs off and keeps the purchase without counting an attempt.
    var isBackoff: Bool {
        if case .server(let status, _, _) = self { return [401, 403, 404, 409, 429].contains(status) }
        return false
    }

    var isConnectivity: Bool {
        switch self {
        case .network, .missingApiKey, .notConfigured: return true
        case .server(let status, _, _): return status >= 500
        default: return false
        }
    }

    /// How long the server asked us to wait, if it did.
    var retryAfter: TimeInterval? {
        if case .server(_, _, let retryAfter) = self { return retryAfter }
        return nil
    }
}

/// One HTTP answer: body, status and the raw `Retry-After` header.
struct BillingHTTPResponse: Sendable {
    let data: Data
    let status: Int
    var retryAfter: String? = nil
}

/// Sends one HTTP request. Abstracted so request building and failover are testable.
protocol BillingTransport: Sendable {
    /// Returns the answer; throws `AppReferBillingError.network` when unreachable.
    func send(_ request: URLRequest) async throws -> BillingHTTPResponse
}

struct URLSessionBillingTransport: BillingTransport {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    func send(_ request: URLRequest) async throws -> BillingHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppReferBillingError.invalidResponse }
            return BillingHTTPResponse(data: data, status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch let error as AppReferBillingError {
            throw error
        } catch {
            throw AppReferBillingError.network(error.localizedDescription)
        }
    }
}

/// Client for `/api/billing/v1/*`. Tries the tracking host first, then the main
/// host, like the attribution client.
struct BillingAPIClient: Sendable {
    enum Endpoint: Equatable {
        case createCustomer(appUserId: String, appreferId: String?, attributes: [String: String])
        case getCustomer(appUserId: String)
        /// `restore` is true only for Restore Purchases: it lets the server move a purchase
        /// that already belongs to another app user to this one.
        case purchase(appUserId: String, appreferId: String?, signedTransaction: String, attributes: [String: String], restore: Bool, presentedOfferingContext: PresentedOfferingContext? = nil, bucketId: String? = nil)
        case identify(anonymousId: String, appUserId: String, link: Bool = true)
        case offerings(body: [String: String], known: [String: String]?)
    }

    private let baseURLProvider: @Sendable () -> [String]
    /// Hosts tried in order, read per request (they follow the install's tracking consent).
    var baseURLs: [String] {
        var unique: [String] = []
        for url in baseURLProvider() where !unique.contains(url) { unique.append(url) }
        return unique
    }
    let apiKey: @Sendable () -> String?
    let transport: BillingTransport
    let timeout: TimeInterval
    /// 100 ms polls while waiting for the SDK key.
    let keyWaitAttempts: Int
    let environment: BillingEnvironment?

    init(
        baseURLs: [String],
        apiKey: @escaping @Sendable () -> String?,
        transport: BillingTransport,
        timeout: TimeInterval = 15,
        keyWaitAttempts: Int = 30,
        environment: BillingEnvironment? = nil
    ) {
        self.init(baseURLProvider: { baseURLs }, apiKey: apiKey, transport: transport, timeout: timeout, keyWaitAttempts: keyWaitAttempts, environment: environment)
    }

    init(
        baseURLProvider: @escaping @Sendable () -> [String],
        apiKey: @escaping @Sendable () -> String?,
        transport: BillingTransport,
        timeout: TimeInterval = 15,
        keyWaitAttempts: Int = 30,
        environment: BillingEnvironment? = nil
    ) {
        self.baseURLProvider = baseURLProvider
        self.apiKey = apiKey
        self.transport = transport
        self.timeout = timeout
        self.keyWaitAttempts = keyWaitAttempts
        self.environment = environment
    }

    static func makeRequest(_ endpoint: Endpoint, baseURL: String, apiKey: String, timeout: TimeInterval = 15) throws -> URLRequest {
        let path: String
        var method = "POST"
        var query: [URLQueryItem] = []
        var body: [String: Any]?

        switch endpoint {
        case let .offerings(fields, known):
            path = "/api/billing/v1/offerings"
            var b: [String: Any] = fields
            if let known { b["known"] = known }
            body = b
        case let .createCustomer(appUserId, appreferId, attributes):
            path = "/api/billing/v1/customers"
            var b: [String: Any] = ["appUserId": appUserId]
            if let appreferId { b["appreferId"] = appreferId }
            if !attributes.isEmpty { b["attributes"] = attributes }
            body = b
        case let .getCustomer(appUserId):
            path = "/api/billing/v1/customers"
            method = "GET"
            query = [URLQueryItem(name: "appUserId", value: appUserId)]
        case let .purchase(appUserId, appreferId, signedTransaction, attributes, restore, context, bucketId):
            path = "/api/billing/v1/purchases"
            var b: [String: Any] = [
                "appUserId": appUserId,
                "store": "app_store",
                "signedTransaction": signedTransaction,
            ]
            if let appreferId { b["appreferId"] = appreferId }
            if !attributes.isEmpty { b["attributes"] = attributes }
            if restore { b["restore"] = true }
            if let context { b["presentedOfferingContext"] = context.dictionary }
            if let bucketId { b["bucketId"] = bucketId }
            body = b
        case let .identify(anonymousId, appUserId, link):
            path = "/api/billing/v1/identify"
            body = ["anonymousId": anonymousId, "appUserId": appUserId, "link": link]
        }

        guard var components = URLComponents(string: baseURL + path), components.host != nil else {
            throw AppReferBillingError.network("invalid base URL \(baseURL)")
        }
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves "+" alone, but servers decode it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw AppReferBillingError.network("invalid URL") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "X-AppRefer-Key")
        request.setValue(AppReferVersion.current, forHTTPHeaderField: "X-SDK-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    /// `AppRefer.configure` usually runs in a Task started just before
    /// `AppReferBilling.configure`, so give it a moment to register the key.
    private func resolveApiKey() async -> String? {
        for attempt in 0...keyWaitAttempts {
            if let key = apiKey(), !key.isEmpty { return key }
            if attempt < keyWaitAttempts { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        return nil
    }

    /// Sends the request. 5xx and network errors fail over to the next host; 4xx are final.
    func send(_ endpoint: Endpoint) async throws -> BillingCustomerResponse {
        do {
            let response = try JSONDecoder().decode(BillingCustomerResponse.self, from: try await sendRaw(endpoint))
            if let environment, response.info.environment != environment { throw AppReferBillingError.invalidResponse }
            return response
        }
        catch let error as AppReferBillingError { throw error }
        catch { throw AppReferBillingError.invalidResponse }
    }
    func sendRaw(_ endpoint: Endpoint) async throws -> Data {
        guard let key = await resolveApiKey() else { throw AppReferBillingError.missingApiKey }
        var lastError = AppReferBillingError.network("no endpoint")

        for baseURL in baseURLs {
            var request = try Self.makeRequest(endpoint, baseURL: baseURL, apiKey: key, timeout: timeout)
            if let environment {
                _ = try BillingEnvironment.select(apiKey: key, explicit: environment)
                request.setValue(environment.rawValue, forHTTPHeaderField: "X-AppRefer-Billing-Environment")
            }
            let response: BillingHTTPResponse
            do {
                response = try await transport.send(request)
            } catch let error as AppReferBillingError {
                lastError = Self.keepingServerAnswer(lastError, over: error)
                continue
            } catch {
                lastError = Self.keepingServerAnswer(lastError, over: .network(error.localizedDescription))
                continue
            }

            let (data, status) = (response.data, response.status)
            if (200..<300).contains(status) {
                if case .purchase = endpoint, !Self.isRecorded(data) {
                    // Older servers answered 200 when the purchase was verified but not
                    // recorded; treat it like today's 503 so the retry copy is kept.
                    throw AppReferBillingError.server(
                        status: 503, message: "Purchase verified but not recorded yet", retryAfter: Self.defaultRetryAfter
                    )
                }
                return data
            }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            let error = AppReferBillingError.server(
                status: status, message: message, retryAfter: Self.parseRetryAfter(response.retryAfter, now: Date())
            )
            if status >= 500 {
                lastError = Self.keepingServerAnswer(lastError, over: error)
                continue
            }
            throw error
        }
        throw lastError
    }

    static let defaultRetryAfter: TimeInterval = 30

    /// The error to report after another host failed. A host that answered beats one that
    /// didn't (AppRefer is up, and its `Retry-After` must be honoured), and a later 5xx
    /// without `Retry-After` keeps the wait an earlier host asked for.
    static func keepingServerAnswer(_ earlier: AppReferBillingError, over later: AppReferBillingError) -> AppReferBillingError {
        guard case .server(_, _, let earlierWait) = earlier else { return later }
        guard case .server(let status, let message, let wait) = later else { return earlier }
        let longest = [earlierWait, wait].compactMap { $0 }.max()
        return .server(status: status, message: message, retryAfter: longest)
    }

    /// False only when a 2xx purchase answer says the ledger write failed.
    static func isRecorded(_ data: Data) -> Bool {
        let purchase = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["purchase"] as? [String: Any]
        return purchase?["conversion"] as? String != "failed"
    }

    /// `Retry-After` as delay-seconds or an HTTP date; nil when absent or unreadable.
    static func parseRetryAfter(_ raw: String?, now: Date) -> TimeInterval? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return seconds >= 0 ? TimeInterval(seconds) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
