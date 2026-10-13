import XCTest
@testable import AppRefer

final class BillingStorageTests: XCTestCase {
    private var env: BillingTestEnvironment!

    override func setUp() {
        super.setUp()
        env = BillingTestEnvironment()
    }

    override func tearDown() {
        env.cleanUp()
        super.tearDown()
    }

    // MARK: - Anonymous id

    func testAnonymousIdFormatMatchesServer() throws {
        let id = env.storage().anonymousId()
        // Server: /^\$ARAnon:[0-9a-fA-F-]{36}$/
        let regex = try NSRegularExpression(pattern: "^\\$ARAnon:[0-9a-fA-F-]{36}$")
        XCTAssertEqual(regex.numberOfMatches(in: id, range: NSRange(id.startIndex..., in: id)), 1, id)
        XCTAssertTrue(BillingStorage.isAnonymous(id))
    }

    func testAnonymousIdIsMintedOnceAndSurvivesReinstall() {
        let first = env.storage().anonymousId()
        XCTAssertEqual(env.storage().anonymousId(), first, "same storage → same id")

        // Reinstall: UserDefaults and files are gone, the Keychain item remains.
        let reinstalled = BillingTestEnvironment(secure: env.secure)
        defer { reinstalled.cleanUp() }
        XCTAssertEqual(reinstalled.storage().anonymousId(), first)
        XCTAssertEqual(reinstalled.storage().currentAppUserId, first)
    }

    func testResetAnonymousIdMintsNewOne() {
        let storage = env.storage()
        XCTAssertFalse(storage.hasAnonymousId)
        let first = storage.anonymousId()
        XCTAssertTrue(storage.hasAnonymousId)
        let second = storage.resetAnonymousId()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(storage.anonymousId(), second)
    }

    func testCurrentAppUserIdPrefersLoggedInUser() {
        let storage = env.storage()
        storage.loggedInAppUserId = "user_1"
        XCTAssertEqual(storage.currentAppUserId, "user_1")
        storage.loggedInAppUserId = nil
        XCTAssertTrue(BillingStorage.isAnonymous(storage.currentAppUserId))
    }

    // MARK: - Other state

    func testAccountTokensArePerUserAndValidated() {
        let storage = env.storage()
        storage.setAccountToken("6F9619FF-8B86-D011-B42D-00C04FC964FF", for: "a")
        storage.setAccountToken("not-a-uuid", for: "b")
        XCTAssertEqual(storage.accountToken(for: "a"), UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertNil(storage.accountToken(for: "b"))
    }

    func testPendingAttributesClearOnlyWhatWasSent() {
        let storage = env.storage()
        storage.mergePendingAttributes(["$email": "a@example.com", "$displayName": "A"])
        let sent = storage.pendingAttributes
        storage.mergePendingAttributes(["$email": "b@example.com"]) // changed while in flight
        storage.clearSentAttributes(sent)
        XCTAssertEqual(storage.pendingAttributes, ["$email": "b@example.com"])
    }

    func testLearnsEntitlementsFromServer() throws {
        let storage = env.storage()
        let info = try JSONDecoder().decode(
            AppReferCustomerInfo.self,
            from: Data(BillingFixtures.customerJSON(appUserId: "u", entitlement: "pro", productId: "pro_monthly").utf8)
        )
        storage.learnEntitlements(from: info)
        XCTAssertEqual(storage.learnedEntitlements, ["pro_monthly": ["pro"]])
    }

    func testCachedCustomerInfoPersists() throws {
        let info = try JSONDecoder().decode(AppReferCustomerInfo.self, from: Data(BillingFixtures.customerJSON(appUserId: "u").utf8))
        env.storage().setCachedCustomerInfo(info)
        XCTAssertEqual(env.storage().cachedCustomerInfo(), info)
    }

    func testPendingIdentifyPersists() {
        env.storage().pendingIdentify = ("$ARAnon:6F9619FF-8B86-D011-B42D-00C04FC964FF", "user_1")
        XCTAssertEqual(env.storage().pendingIdentify?.appUserId, "user_1")
        env.storage().pendingIdentify = nil
        XCTAssertNil(env.storage().pendingIdentify)
    }

    // MARK: - Retry queue

    private func entry(_ id: String, attempts: Int = 1, enqueuedAt: Date = BillingFixtures.now) -> PendingPurchase {
        PendingPurchase(
            transactionId: id, productId: "pro_yearly", appUserId: "user_1", appreferId: "device",
            signedTransaction: "jws.\(id)", enqueuedAt: enqueuedAt, attempts: attempts
        )
    }

    func testQueuePersistsAcrossLaunches() {
        let queue = env.queue()
        queue.add(entry("t1"))
        queue.add(entry("t2"))

        let relaunched = env.queue()
        XCTAssertEqual(relaunched.entries.map(\.transactionId), ["t1", "t2"])
        XCTAssertEqual(relaunched.entries.first?.signedTransaction, "jws.t1")
        XCTAssertTrue(relaunched.contains(appUserId: "user_1"))
        XCTAssertFalse(relaunched.contains(appUserId: "user_2"))
    }

    func testQueueDedupesByTransactionAndTracksAttempts() {
        let queue = env.queue()
        queue.add(entry("t1"))
        queue.add(entry("t1"))
        queue.recordAttempt(transactionId: "t1")
        XCTAssertEqual(queue.entries.count, 1)
        XCTAssertEqual(env.queue().entries.first?.attempts, 2)

        queue.remove(transactionId: "t1")
        XCTAssertTrue(env.queue().isEmpty)
    }

    func testQueuePrunesTooManyAttemptsAndTooOld() {
        let queue = env.queue()
        queue.add(entry("fresh"))
        queue.add(entry("tired", attempts: PendingPurchaseQueue.maxAttempts))
        queue.add(entry("old", enqueuedAt: BillingFixtures.now.addingTimeInterval(-PendingPurchaseQueue.maxAge - 1)))

        let dropped = queue.prune(now: BillingFixtures.now)
        XCTAssertEqual(Set(dropped.map(\.transactionId)), ["tired", "old"])
        XCTAssertEqual(env.queue().entries.map(\.transactionId), ["fresh"])
    }

    func testCorruptQueueFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: env.directory.appendingPathComponent("pending_purchases.json"))
        XCTAssertTrue(env.queue().isEmpty)
    }
}
