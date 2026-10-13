import Foundation

/// Core of AppReferBilling: identity, server sync, transaction processing, retry queue
/// and the outage fallback. StoreKit purchase UI lives in `AppReferBilling`; everything
/// here goes through `BillingStoreKit` and `BillingAPIClient` so it can be tested.
@available(iOS 15.0, macOS 12.0, *)
actor BillingEngine {
    struct Options: Sendable {
        var productEntitlements: [String: [String]] = [:]
        var defaultEntitlement: String?
        /// How long a server answer counts as fresh for `.cachedOrFetched`.
        var cacheTTL: TimeInterval = 5 * 60
    }

    private let api: BillingAPIClient
    private let storage: BillingStorage
    private let queue: PendingPurchaseQueue
    private let storeKit: BillingStoreKit
    private let options: Options
    private let appreferId: @Sendable () -> String?
    private let logger: AppReferLogger
    private let onChange: @Sendable (AppReferCustomerInfo) -> Void
    private let now: @Sendable () -> Date

    private var lastPublished: AppReferCustomerInfo?
    private var lastServerFetch: (appUserId: String, at: Date)?
    /// Users whose appreferId/attributes were registered (POST customers) this launch.
    private var registeredUsers = Set<String>()
    private var updatesTask: Task<Void, Never>?
    private var isDraining = false

    init(
        api: BillingAPIClient,
        storage: BillingStorage,
        queue: PendingPurchaseQueue,
        storeKit: BillingStoreKit,
        options: Options,
        appUserId: String?,
        appreferId: @escaping @Sendable () -> String?,
        logger: AppReferLogger,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping @Sendable (AppReferCustomerInfo) -> Void = { _ in }
    ) {
        self.api = api
        self.storage = storage
        self.queue = queue
        self.storeKit = storeKit
        self.options = options
        self.appreferId = appreferId
        self.logger = logger
        self.now = now
        self.onChange = onChange

        // configure(appUserId:) behaves like logIn: purchases made while anonymous
        // on this device move to the user (sent to /identify when reachable).
        if let appUserId, !appUserId.isEmpty, appUserId != storage.loggedInAppUserId {
            if storage.loggedInAppUserId == nil, storage.hasAnonymousId, !BillingStorage.isAnonymous(appUserId) {
                storage.pendingIdentify = (storage.anonymousId(), appUserId)
            }
            storage.loggedInAppUserId = BillingStorage.isAnonymous(appUserId) ? nil : appUserId
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the `Transaction.updates` listener, finishes anything StoreKit still has
    /// unfinished, flushes the retry queue and refreshes entitlements.
    func start() async {
        if updatesTask == nil {
            let stream = storeKit.transactionUpdates()
            updatesTask = Task { [weak self] in
                for await update in stream {
                    guard let self else { return }
                    _ = await self.process(update)
                }
            }
        }
        for update in await storeKit.unfinishedTransactions() {
            _ = await process(update)
        }
        _ = await customerInfo(policy: .fetchCurrent)
    }

    var currentAppUserId: String { storage.currentAppUserId }
    var isAnonymous: Bool { storage.loggedInAppUserId == nil }

    // MARK: - CustomerInfo

    func customerInfo(policy: AppReferBilling.FetchPolicy) async -> AppReferCustomerInfo {
        let user = currentAppUserId
        if policy == .cachedOrFetched,
           let fetched = lastServerFetch, fetched.appUserId == user,
           now().timeIntervalSince(fetched.at) < options.cacheTTL,
           let cached = storage.cachedCustomerInfo(), cached.appUserId == user {
            return publish(await withPendingLocal(cached.reevaluated(at: now())))
        }
        do {
            return try await fetchFromServer()
        } catch {
            logger.warn("Billing: customer refresh failed (\(error.localizedDescription)); using StoreKit fallback")
            return await localFallback()
        }
    }

    private func fetchFromServer() async throws -> AppReferCustomerInfo {
        await flushPendingIdentify()
        let user = currentAppUserId
        let attributes = storage.pendingAttributes
        let needsRegister = !registeredUsers.contains(user) || !attributes.isEmpty || storage.accountToken(for: user) == nil
        let response = try await api.send(
            needsRegister
                ? .createCustomer(appUserId: user, appreferId: appreferId(), attributes: attributes)
                : .getCustomer(appUserId: user)
        )
        if needsRegister {
            registeredUsers.insert(user)
            storage.clearSentAttributes(attributes)
        }
        let info = await accept(response, for: user)
        await drainQueue()
        return info
    }

    /// Stores a server answer and returns what callers should see.
    private func accept(_ response: BillingCustomerResponse, for user: String) async -> AppReferCustomerInfo {
        if let token = response.accountToken { storage.setAccountToken(token, for: response.info.appUserId) }
        storage.learnEntitlements(from: response.info)
        guard response.info.appUserId == user, user == currentAppUserId else {
            // Answer for a user who is no longer current (logIn/logOut raced it).
            return response.info
        }
        storage.setCachedCustomerInfo(response.info)
        lastServerFetch = (user, now())
        return publish(await withPendingLocal(response.info))
    }

    /// While a purchase for this user is still queued, the server can't know it yet,
    /// so device entitlements are merged in.
    private func withPendingLocal(_ info: AppReferCustomerInfo) async -> AppReferCustomerInfo {
        guard queue.contains(appUserId: info.appUserId) else { return info }
        let transactions = await storeKit.currentEntitlements()
        return mergeLocal(into: info, transactions: transactions, user: info.appUserId, source: info.source)
    }

    /// Outage path: verified StoreKit entitlements merged with the cached server answer.
    /// A paying user is never locked out because AppRefer is down.
    func localFallback() async -> AppReferCustomerInfo {
        let user = currentAppUserId
        let transactions = await storeKit.currentEntitlements()
        let cached = storage.cachedCustomerInfo().flatMap { $0.appUserId == user ? $0.reevaluated(at: now()) : nil }
        let merged = mergeLocal(into: cached, transactions: transactions, user: user, source: .localFallback)
        return publish(merged)
    }

    private func mergeLocal(
        into server: AppReferCustomerInfo?,
        transactions: [StoreTransaction],
        user: String,
        source: AppReferCustomerInfo.Source
    ) -> AppReferCustomerInfo {
        let local = LocalEntitlements.compute(
            transactions: transactions,
            configured: options.productEntitlements,
            learned: storage.learnedEntitlements,
            defaultEntitlement: options.defaultEntitlement,
            now: now()
        )
        return LocalEntitlements.merge(server: server, local: local, appUserId: user, now: now(), source: source)
    }

    @discardableResult
    private func publish(_ info: AppReferCustomerInfo) -> AppReferCustomerInfo {
        if lastPublished.map({ !$0.hasSameContent(as: info) }) ?? true {
            onChange(info)
        }
        lastPublished = info
        return info
    }

    // MARK: - Transactions

    /// Sends a StoreKit transaction to AppRefer, then finishes it. If AppRefer can't
    /// take it now, the signed transaction is queued on disk and the transaction is
    /// still finished, so StoreKit never keeps redelivering it; access comes from the
    /// verified transaction meanwhile.
    func process(_ update: StoreKitUpdate) async -> AppReferCustomerInfo {
        guard let transaction = update.verified else {
            logger.error("Billing: unverified transaction \(update.transactionId) finished without granting access")
            await update.finish()
            return await localFallback()
        }

        let user = currentAppUserId
        let attributes = storage.pendingAttributes
        let deviceId = appreferId()
        do {
            let response = try await api.send(.purchase(
                appUserId: user,
                appreferId: deviceId,
                signedTransaction: transaction.signedTransaction,
                attributes: attributes
            ))
            storage.clearSentAttributes(attributes)
            await update.finish()
            let info = await accept(response, for: user)
            await drainQueue()
            return info
        } catch let error as AppReferBillingError where error.isRetryable {
            logger.warn("Billing: queued transaction \(transaction.id) for retry (\(error.localizedDescription))")
            queue.add(PendingPurchase(
                transactionId: transaction.id,
                productId: transaction.productId,
                appUserId: user,
                appreferId: deviceId,
                signedTransaction: transaction.signedTransaction,
                enqueuedAt: now(),
                attempts: 1
            ))
        } catch {
            // Rejected as malformed: retrying won't help. StoreKit verified it, so the
            // device fallback still unlocks it; App Store notifications reach the server.
            logger.error("Billing: AppRefer rejected transaction \(transaction.id): \(error.localizedDescription)")
        }
        await update.finish()
        return await localFallback()
    }

    /// `AppStore.sync()` then sends every current entitlement to AppRefer.
    func restore() async throws -> AppReferCustomerInfo {
        try await storeKit.sync()
        let transactions = await storeKit.currentEntitlements()
        guard !transactions.isEmpty else { return await customerInfo(policy: .fetchCurrent) }

        await flushPendingIdentify()
        let user = currentAppUserId
        let deviceId = appreferId()
        var last: BillingCustomerResponse?
        var failed = false
        for transaction in transactions {
            do {
                last = try await api.send(.purchase(
                    appUserId: user, appreferId: deviceId,
                    signedTransaction: transaction.signedTransaction, attributes: [:]
                ))
            } catch let error as AppReferBillingError where error.isRetryable {
                failed = true
                queue.add(PendingPurchase(
                    transactionId: transaction.id, productId: transaction.productId, appUserId: user,
                    appreferId: deviceId, signedTransaction: transaction.signedTransaction,
                    enqueuedAt: now(), attempts: 1
                ))
                if error.isConnectivity { break }
            } catch {
                failed = true
            }
        }
        if let last, !failed { return await accept(last, for: user) }
        if let last { _ = await accept(last, for: user) }
        return await localFallback()
    }

    /// Re-sends queued transactions. Stops at the first connectivity failure.
    func drainQueue() async {
        guard !isDraining, !queue.isEmpty else { return }
        isDraining = true
        defer { isDraining = false }

        for dropped in queue.prune(now: now()) {
            logger.error("Billing: gave up resending transaction \(dropped.transactionId) after \(dropped.attempts) attempts")
        }
        for entry in queue.entries {
            do {
                let response = try await api.send(.purchase(
                    appUserId: entry.appUserId, appreferId: entry.appreferId,
                    signedTransaction: entry.signedTransaction, attributes: [:]
                ))
                queue.remove(transactionId: entry.transactionId)
                if entry.appUserId == currentAppUserId { _ = await accept(response, for: entry.appUserId) }
            } catch let error as AppReferBillingError where error.isRetryable {
                queue.recordAttempt(transactionId: entry.transactionId)
                if error.isConnectivity { return }
            } catch {
                queue.remove(transactionId: entry.transactionId)
            }
        }
    }

    // MARK: - Purchases

    /// The Apple `appAccountToken` for the current user, fetched from AppRefer if not cached.
    /// Nil when AppRefer is unreachable: the purchase still goes ahead.
    func accountToken() async -> UUID? {
        let user = currentAppUserId
        if let token = storage.accountToken(for: user) { return token }
        _ = try? await fetchFromServer()
        return storage.accountToken(for: user)
    }

    // MARK: - Identity

    func logIn(_ appUserId: String) async throws -> AppReferCustomerInfo {
        guard Self.isValid(appUserId), !BillingStorage.isAnonymous(appUserId) else {
            throw AppReferBillingError.invalidAppUserId
        }
        if appUserId != currentAppUserId {
            if isAnonymous { storage.pendingIdentify = (storage.anonymousId(), appUserId) }
            storage.loggedInAppUserId = appUserId
            lastServerFetch = nil
        }
        return await customerInfo(policy: .fetchCurrent)
    }

    func logOut() async -> AppReferCustomerInfo {
        storage.loggedInAppUserId = nil
        storage.pendingIdentify = nil
        storage.resetAnonymousId()
        lastServerFetch = nil
        return await customerInfo(policy: .fetchCurrent)
    }

    func setAttributes(_ attributes: [String: String]) {
        storage.mergePendingAttributes(attributes)
    }

    private func flushPendingIdentify() async {
        guard let pending = storage.pendingIdentify else { return }
        do {
            _ = try await api.send(.identify(anonymousId: pending.anonymousId, appUserId: pending.appUserId))
            storage.pendingIdentify = nil
        } catch let error as AppReferBillingError where error.isRetryable {
            logger.warn("Billing: identify will be retried (\(error.localizedDescription))")
        } catch {
            storage.pendingIdentify = nil
        }
    }

    static func isValid(_ appUserId: String) -> Bool {
        !appUserId.isEmpty && appUserId.count <= 256 && appUserId.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
}
