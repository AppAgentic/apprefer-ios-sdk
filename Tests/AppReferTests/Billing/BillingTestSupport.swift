import Foundation
@testable import AppRefer

/// Scripted HTTP transport: records every request and answers through `handler`.
final class MockBillingTransport: BillingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _retryAfter: String?
    var handler: @Sendable (URLRequest) throws -> (Data, Int)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    /// `Retry-After` header sent with every non-2xx answer.
    var retryAfter: String? {
        get { lock.lock(); defer { lock.unlock() }; return _retryAfter }
        set { lock.lock(); _retryAfter = newValue; lock.unlock() }
    }

    func send(_ request: URLRequest) async throws -> BillingHTTPResponse {
        let (data, status) = try record(request)(request)
        return BillingHTTPResponse(data: data, status: status, retryAfter: (200..<300).contains(status) ? nil : retryAfter)
    }

    private func record(_ request: URLRequest) -> @Sendable (URLRequest) throws -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
        return handler
    }

    func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    func setHandler(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func unreachable() -> MockBillingTransport {
        MockBillingTransport { _ in throw AppReferBillingError.network("offline") }
    }

    static func ok(_ json: String) -> MockBillingTransport {
        MockBillingTransport { _ in (Data(json.utf8), 200) }
    }
}

final class FakeStoreKit: BillingStoreKit, @unchecked Sendable {
    var entitlements: [StoreTransaction]
    var unfinished: [StoreKitUpdate] = []
    var syncCalls = 0

    init(entitlements: [StoreTransaction] = []) {
        self.entitlements = entitlements
    }

    func currentEntitlements() async -> [StoreTransaction] { entitlements }
    func unfinishedTransactions() async -> [StoreKitUpdate] { unfinished }
    func transactionUpdates() -> AsyncStream<StoreKitUpdate> { AsyncStream { $0.finish() } }
    func sync() async throws { syncCalls += 1 }
}

/// Counts `finish()` calls for a fake StoreKit update.
final class FinishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
    func increment() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}

enum BillingFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func transaction(
        id: String = "2000000000000001",
        productId: String = "pro_yearly",
        kind: StoreTransaction.Kind = .autoRenewable,
        expires: Date? = now.addingTimeInterval(86_400),
        revoked: Date? = nil,
        upgraded: Bool = false,
        appAccountToken: UUID? = nil
    ) -> StoreTransaction {
        StoreTransaction(
            id: id, originalId: "orig-\(id)", productId: productId, kind: kind,
            purchaseDate: now.addingTimeInterval(-3600), expirationDate: expires,
            revocationDate: revoked, isUpgraded: upgraded, periodType: .normal,
            signedTransaction: "jws.\(id).sig", appAccountToken: appAccountToken
        )
    }

    static let accountToken = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let otherAccountToken = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    static func update(_ t: StoreTransaction?, id: String = "1", counter: FinishCounter) -> StoreKitUpdate {
        StoreKitUpdate(verified: t, transactionId: t?.id ?? id, finish: { counter.increment() })
    }

    /// Server CustomerInfo JSON with one entitlement.
    static func customerJSON(
        appUserId: String,
        entitlement: String = "premium",
        productId: String = "pro_yearly",
        isActive: Bool = true,
        expiresAtMs: Double? = (now.timeIntervalSince1970 + 86_400) * 1000,
        accountToken: String? = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    ) -> String {
        let expires = expiresAtMs.map { String(Int64($0)) } ?? "null"
        let token = accountToken.map { ",\"accountToken\":\"\($0)\"" } ?? ""
        return """
        {"appUserId":"\(appUserId)","entitlements":{"\(entitlement)":{"id":"\(entitlement)","isActive":\(isActive),\
        "productId":"\(productId)","store":"app_store","expiresAtMs":\(expires),"willRenew":true,"periodType":"normal",\
        "state":"active","subscriptionKey":"2000000000000001"}},"activeSubscriptions":\(isActive ? "[\"\(productId)\"]" : "[]"),\
        "requestDateMs":\(Int64(now.timeIntervalSince1970 * 1000))\(token)}
        """
    }

    static func emptyCustomerJSON(appUserId: String) -> String {
        """
        {"appUserId":"\(appUserId)","entitlements":{},"activeSubscriptions":[],"requestDateMs":\(Int64(now.timeIntervalSince1970 * 1000)),"accountToken":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}
        """
    }
}

/// Fresh, isolated storage (temp directory, private UserDefaults, in-memory keychain).
struct BillingTestEnvironment {
    let directory: URL
    let defaults: UserDefaults
    let suiteName: String
    let secure: InMemoryBillingSecureStore

    init(secure: InMemoryBillingSecureStore = InMemoryBillingSecureStore()) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("apprefer-billing-\(UUID().uuidString)")
        suiteName = "com.apprefer.billing.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        self.secure = secure
    }

    func storage() -> BillingStorage {
        BillingStorage(secure: secure, defaults: defaults, directory: directory)
    }

    func queue() -> PendingPurchaseQueue {
        PendingPurchaseQueue(fileURL: directory.appendingPathComponent("pending_purchases.json"))
    }

    @available(iOS 15.0, macOS 12.0, *)
    func engine(
        transport: BillingTransport,
        storeKit: BillingStoreKit = FakeStoreKit(),
        options: BillingEngine.Options = .init(),
        appUserId: String? = nil,
        storage: BillingStorage? = nil,
        queue: PendingPurchaseQueue? = nil,
        apiKey: String? = "pk_test_123",
        now: @escaping @Sendable () -> Date = { BillingFixtures.now }
    ) -> BillingEngine {
        BillingEngine(
            api: BillingAPIClient(
                baseURLs: ["https://trk.example.com", "https://main.example.com"],
                apiKey: { apiKey },
                transport: transport,
                keyWaitAttempts: 0
            ),
            storage: storage ?? self.storage(),
            queue: queue ?? self.queue(),
            storeKit: storeKit,
            options: options,
            appUserId: appUserId,
            appreferId: { "device-abc" },
            logger: AppReferLogger(debug: false, logLevel: 0),
            now: now
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// Settable clock for back-off tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = BillingFixtures.now
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        _now = _now.addingTimeInterval(seconds)
        lock.unlock()
    }
}
