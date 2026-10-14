import Foundation

/// Core of AppReferBilling: identity, server sync, transaction processing, retry queue
/// and the outage fallback. StoreKit purchase UI lives in `AppReferBilling`; everything
/// here goes through `BillingStoreKit` and `BillingAPIClient` so it can be tested.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
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
    /// Retry queue back-off after 401/403/404/409/429.
    private var drainBackoff: (until: Date, delay: TimeInterval)?
    static let minBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 3600

    /// Identity changes requested while protected data was unavailable (before first
    /// unlock), applied in order once the Keychain can be read.
    private enum IdentityChange { case configure(String), logIn(String), logOut }
    private var pendingIdentityChanges: [IdentityChange] = []
    /// Transactions delivered while protected data was unavailable. Left unfinished so
    /// StoreKit keeps them; processed once the user's identity can be read.
    private var deferredUpdates: [StoreKitUpdate] = []

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

        if let appUserId, !appUserId.isEmpty {
            if storage.isProtectedDataAvailable {
                Self.applyConfigure(appUserId, storage: storage)
            } else {
                pendingIdentityChanges = [.configure(appUserId)]
            }
        }
    }

    /// configure(appUserId:) behaves like logIn: purchases made while anonymous on this
    /// device move to the user (sent to /identify when reachable).
    private static func applyConfigure(_ appUserId: String, storage: BillingStorage) {
        guard appUserId != storage.loggedInAppUserId else { return }
        if storage.loggedInAppUserId == nil, storage.hasAnonymousId, !BillingStorage.isAnonymous(appUserId),
           let anonymousId = storage.anonymousId() {
            storage.addPendingIdentify(anonymousId: anonymousId, appUserId: appUserId)
        }
        storage.loggedInAppUserId = BillingStorage.isAnonymous(appUserId) ? nil : appUserId
    }

    /// The current app user, or nil while protected data is unavailable. Applies identity
    /// changes that were waiting for the Keychain.
    private func activeUser() -> String? {
        guard storage.isProtectedDataAvailable else { return nil }
        if !pendingIdentityChanges.isEmpty {
            let changes = pendingIdentityChanges
            pendingIdentityChanges = []
            for change in changes { apply(change) }
        }
        return storage.currentAppUserId
    }

    private func apply(_ change: IdentityChange) {
        switch change {
        case .configure(let appUserId):
            Self.applyConfigure(appUserId, storage: storage)
        case .logIn(let appUserId):
            guard appUserId != storage.currentAppUserId else { return }
            if storage.loggedInAppUserId == nil, let anonymousId = storage.anonymousId() {
                storage.addPendingIdentify(anonymousId: anonymousId, appUserId: appUserId)
            }
            storage.loggedInAppUserId = appUserId
            lastServerFetch = nil
        case .logOut:
            // Pending identifies stay: they still have to reach the server.
            storage.loggedInAppUserId = nil
            storage.resetAnonymousId()
            lastServerFetch = nil
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

    /// Empty while protected data is unavailable.
    var currentAppUserId: String { activeUser() ?? "" }
    var isAnonymous: Bool { activeUser().map(BillingStorage.isAnonymous) ?? true }

    // MARK: - CustomerInfo

    func customerInfo(policy: AppReferBilling.FetchPolicy) async -> AppReferCustomerInfo {
        guard let user = activeUser() else { return await lockedFallback() }
        await processDeferredUpdates()
        if policy == .cachedOrFetched,
           let fetched = lastServerFetch, fetched.appUserId == user,
           now().timeIntervalSince(fetched.at) < options.cacheTTL,
           let cached = storage.cachedCustomerInfo(), cached.appUserId == user {
            return publish(await withPendingLocal(cached.reevaluated(at: now())))
        }
        do {
            return try await fetchFromServer(user)
        } catch {
            logger.warn("Billing: customer refresh failed (\(error.localizedDescription)); using StoreKit fallback")
            return await localFallback()
        }
    }

    private func fetchFromServer(_ user: String) async throws -> AppReferCustomerInfo {
        await flushPendingIdentifies()
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
        guard response.info.appUserId == user, user == activeUser() else {
            // Answer for a user who is no longer current (logIn/logOut raced it).
            return response.info
        }
        storage.setCachedCustomerInfo(response.info)
        lastServerFetch = (user, now())
        return publish(await withPendingLocal(response.info))
    }

    /// Merges this user's verified StoreKit entitlements into a server answer, so a payer
    /// is never locked out when the server didn't get the purchase (upload dropped or
    /// rejected, or no appAccountToken for the App Store notification to match). A
    /// transaction counts as this user's when it has no appAccountToken, carries this
    /// user's token, or is still queued for them.
    private func withPendingLocal(_ info: AppReferCustomerInfo) async -> AppReferCustomerInfo {
        let user = info.appUserId
        let token = storage.accountToken(for: user)
        let queued = Set(queue.entries.filter { $0.appUserId == user }.map(\.transactionId))
        let transactions = await storeKit.currentEntitlements().filter {
            $0.appAccountToken == nil || $0.appAccountToken == token || queued.contains($0.id)
        }
        guard !transactions.isEmpty else { return info }
        return mergeLocal(into: info, transactions: transactions, user: user, source: info.source)
    }

    /// Before first unlock: the user is unknown, so nothing is sent, cached or published.
    /// Verified StoreKit entitlements still answer.
    private func lockedFallback() async -> AppReferCustomerInfo {
        mergeLocal(into: nil, transactions: await storeKit.currentEntitlements(), user: "", source: .localFallback)
    }

    /// Outage path: verified StoreKit entitlements merged with the cached server answer.
    /// A paying user is never locked out because AppRefer is down.
    func localFallback() async -> AppReferCustomerInfo {
        guard let user = activeUser() else { return await lockedFallback() }
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

        guard let user = activeUser() else {
            // Before first unlock: whose purchase this is can't be read. Keep it
            // unfinished and send it once the identity is readable.
            logger.warn("Billing: protected data unavailable; transaction \(transaction.id) deferred")
            if !deferredUpdates.contains(where: { $0.transactionId == update.transactionId }) {
                deferredUpdates.append(update)
            }
            return await lockedFallback()
        }
        let attributes = storage.pendingAttributes
        let deviceId = appreferId()
        do {
            // Never a restore: purchases and Transaction.updates (renewals included) must
            // not move a purchase owned by another app user to whoever is signed in.
            let response = try await api.send(.purchase(
                appUserId: user,
                appreferId: deviceId,
                signedTransaction: transaction.signedTransaction,
                attributes: attributes,
                restore: false
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
                attempts: error.isBackoff ? 0 : 1
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

        guard let user = activeUser() else { return await lockedFallback() }
        await flushPendingIdentifies()
        let deviceId = appreferId()
        var last: BillingCustomerResponse?
        var failed = false
        for transaction in transactions {
            do {
                last = try await api.send(.purchase(
                    appUserId: user, appreferId: deviceId,
                    signedTransaction: transaction.signedTransaction, attributes: [:], restore: true
                ))
            } catch let error as AppReferBillingError where error.isRetryable {
                failed = true
                queue.add(PendingPurchase(
                    transactionId: transaction.id, productId: transaction.productId, appUserId: user,
                    appreferId: deviceId, signedTransaction: transaction.signedTransaction,
                    enqueuedAt: now(), attempts: error.isBackoff ? 0 : 1, restore: true
                ))
                if error.isConnectivity || error.isBackoff { break }
            } catch {
                failed = true
            }
        }
        if let last, !failed { return await accept(last, for: user) }
        if let last { _ = await accept(last, for: user) }
        return await localFallback()
    }

    /// Re-sends queued transactions. Stops at the first connectivity failure. A
    /// 401/403/404/409/429 stops the drain and backs off without counting an attempt,
    /// so a server-side setup problem never uses up a purchase's retries.
    func drainQueue() async {
        guard !isDraining, activeUser() != nil else { return }
        isDraining = true
        defer { isDraining = false }
        await processDeferredUpdates()
        guard !queue.isEmpty else { return }
        if let backoff = drainBackoff, now() < backoff.until { return }

        for dropped in queue.prune(now: now()) {
            logger.error("Billing: gave up resending transaction \(dropped.transactionId) after \(dropped.attempts) attempts")
        }
        for entry in queue.entries {
            do {
                let response = try await api.send(.purchase(
                    appUserId: entry.appUserId, appreferId: entry.appreferId,
                    signedTransaction: entry.signedTransaction, attributes: [:],
                    restore: entry.restore == true
                ))
                queue.remove(transactionId: entry.transactionId)
                drainBackoff = nil
                if entry.appUserId == activeUser() { _ = await accept(response, for: entry.appUserId) }
            } catch let error as AppReferBillingError where error.isRetryable {
                if error.isBackoff {
                    let delay = min(max((drainBackoff?.delay ?? 0) * 2, Self.minBackoff), Self.maxBackoff)
                    drainBackoff = (now().addingTimeInterval(delay), delay)
                    logger.warn("Billing: AppRefer answered \(error.localizedDescription); retrying queued purchases in \(Int(delay))s")
                    return
                }
                queue.recordAttempt(transactionId: entry.transactionId)
                if error.isConnectivity { return }
            } catch {
                queue.remove(transactionId: entry.transactionId)
            }
        }
    }

    private func processDeferredUpdates() async {
        guard !deferredUpdates.isEmpty, activeUser() != nil else { return }
        let updates = deferredUpdates
        deferredUpdates = []
        for update in updates { _ = await process(update) }
    }

    // MARK: - Purchases

    /// The Apple `appAccountToken` for the current user, fetched from AppRefer if not cached.
    /// Nil when AppRefer is unreachable: the purchase still goes ahead.
    func accountToken() async -> UUID? {
        guard let user = activeUser() else { return nil }
        if let token = storage.accountToken(for: user) { return token }
        _ = try? await fetchFromServer(user)
        return storage.accountToken(for: user)
    }

    // MARK: - Identity

    func logIn(_ appUserId: String) async throws -> AppReferCustomerInfo {
        guard Self.isValid(appUserId), !BillingStorage.isAnonymous(appUserId) else {
            throw AppReferBillingError.invalidAppUserId
        }
        pendingIdentityChanges.append(.logIn(appUserId))
        return await customerInfo(policy: .fetchCurrent)
    }

    func logOut() async -> AppReferCustomerInfo {
        pendingIdentityChanges.append(.logOut)
        return await customerInfo(policy: .fetchCurrent)
    }

    func setAttributes(_ attributes: [String: String]) {
        storage.mergePendingAttributes(attributes)
    }

    /// Sends waiting identifies in order; stops at the first one that should be retried.
    private func flushPendingIdentifies() async {
        for pending in storage.pendingIdentifies {
            do {
                _ = try await api.send(.identify(anonymousId: pending.anonymousId, appUserId: pending.appUserId))
                storage.removePendingIdentify(pending)
            } catch let error as AppReferBillingError where error.isRetryable {
                logger.warn("Billing: identify will be retried (\(error.localizedDescription))")
                return
            } catch {
                storage.removePendingIdentify(pending)
            }
        }
    }

    static func isValid(_ appUserId: String) -> Bool {
        !appUserId.isEmpty && appUserId.count <= 256 && appUserId.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
}
