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
    /// Retry queue pause after 401/403/404/409/429 (doubling) or a `Retry-After`.
    private var drainBackoff: (until: Date, delay: TimeInterval)?
    /// Transactions whose retry copy isn't on disk yet: left unfinished until it is saved
    /// or AppRefer records them.
    private var heldUpdates: [String: StoreKitUpdate] = [:]
    private var identifyFlush: Task<Void, Never>?
    static let minBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 3600

    /// Identity changes requested while protected data was unavailable (before first
    /// unlock), applied in order once the Keychain can be read.
    private enum IdentityChange { case configure(String), logIn(String), logOut }
    private var pendingIdentityChanges: [IdentityChange] = []
    /// Transactions delivered while protected data was unavailable. Left unfinished so
    /// StoreKit keeps them; processed once the user's identity can be read.
    private var deferredUpdates: [StoreKitUpdate] = []
    /// Who started each purchase still waiting in `deferredUpdates`.
    private var deferredInitiators: [String: String] = [:]

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

        if let appUserId, !appUserId.isEmpty,
           !(storage.isProtectedDataAvailable && Self.applyConfigure(appUserId, storage: storage)) {
            pendingIdentityChanges = [.configure(appUserId)]
        }
    }

    /// configure(appUserId:) behaves like logIn: purchases made while anonymous on this
    /// device move to the user (sent to /identify when reachable). False when the stored
    /// identity can't be read yet, so the change must wait.
    private static func applyConfigure(_ appUserId: String, storage: BillingStorage) -> Bool {
        guard appUserId != storage.loggedInAppUserId else { return true }
        if storage.loggedInAppUserId == nil, !BillingStorage.isAnonymous(appUserId) {
            switch storage.storedAnonymousId {
            case .found(let anonymousId): storage.addPendingIdentify(anonymousId: anonymousId, appUserId: appUserId)
            case .absent: break
            case .unknown: return false
            }
        }
        storage.loggedInAppUserId = BillingStorage.isAnonymous(appUserId) ? nil : appUserId
        return true
    }

    /// The current app user, or nil while the identity can't be read (protected data
    /// unavailable, or a Keychain failure). Applies identity changes that were waiting,
    /// in order; one that can't be applied yet stays queued with the rest behind it.
    private func activeUser() -> String? {
        guard storage.isProtectedDataAvailable else { return nil }
        while let change = pendingIdentityChanges.first {
            guard apply(change) else { return nil }
            pendingIdentityChanges.removeFirst()
        }
        return storage.currentAppUserId
    }

    private func apply(_ change: IdentityChange) -> Bool {
        switch change {
        case .configure(let appUserId):
            return Self.applyConfigure(appUserId, storage: storage)
        case .logIn(let appUserId):
            guard appUserId != storage.loggedInAppUserId else { return true }
            if storage.loggedInAppUserId == nil {
                switch storage.storedAnonymousId {
                case .found(let anonymousId):
                    guard anonymousId != appUserId else { return true }
                    storage.addPendingIdentify(anonymousId: anonymousId, appUserId: appUserId)
                case .absent: break
                case .unknown: return false
                }
            }
            storage.loggedInAppUserId = appUserId
            lastServerFetch = nil
            return true
        case .logOut:
            // The new anonymous id must be saved before it is used. Pending identifies
            // stay: they still have to reach the server.
            guard storage.resetAnonymousId() != nil else { return false }
            storage.loggedInAppUserId = nil
            lastServerFetch = nil
            return true
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

    private func fetchFromServer(_ user: String, drain: Bool = true) async throws -> AppReferCustomerInfo {
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
        if drain { await drainQueue() }
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

    /// After a purchase upload failed. If AppRefer answered at all, the customer endpoint
    /// decides, merged with this customer's own StoreKit purchases (`withPendingLocal`);
    /// only a total outage unlocks every verified purchase on the device.
    private func answerAfterUploadFailure(_ error: AppReferBillingError?) async -> AppReferCustomerInfo {
        if error?.isUnreachable != true, let user = activeUser(),
           let info = try? await fetchFromServer(user, drain: false) {
            return info
        }
        return await localFallback()
    }

    /// Outage path: verified StoreKit entitlements merged with the cached server answer.
    /// A paying user is never locked out because AppRefer is down. Only used when the
    /// customer endpoint can't be reached.
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

    /// Sends a StoreKit transaction to AppRefer, then finishes it. If AppRefer can't take
    /// it now, the signed transaction is queued on disk and finished once the queue entry
    /// is saved, so StoreKit doesn't keep redelivering it; access comes from the verified
    /// transaction meanwhile. If the save fails it stays unfinished until it succeeds.
    ///
    /// `initiator` is the app user who started the purchase (captured before the account
    /// token was fetched and the sheet opened). Listener updates have none: they belong
    /// to the user whose account token they carry, else the current user.
    func process(_ update: StoreKitUpdate, initiator: String? = nil) async -> AppReferCustomerInfo {
        guard let transaction = update.verified else {
            logger.error("Billing: unverified transaction \(update.transactionId) finished without granting access")
            await update.finish()
            return await currentAnswerWithoutNetwork()
        }

        guard let user = activeUser() else {
            // Before first unlock: whose purchase this is can't be read. Keep it
            // unfinished and send it once the identity is readable.
            logger.warn("Billing: protected data unavailable; transaction \(transaction.id) deferred")
            if !deferredUpdates.contains(where: { $0.transactionId == update.transactionId }) {
                deferredUpdates.append(update)
            }
            if let initiator { deferredInitiators[update.transactionId] = initiator }
            return await lockedFallback()
        }
        let owner = initiator ?? transaction.appAccountToken.flatMap(storage.appUserId(forAccountToken:)) ?? user
        // Attributes belong to whoever is signed in now.
        let attributes = owner == user ? storage.pendingAttributes : [:]
        let deviceId = appreferId()
        do {
            // Never a restore: purchases and Transaction.updates (renewals included) must
            // not move a purchase owned by another app user to whoever is signed in.
            let response = try await api.send(.purchase(
                appUserId: owner,
                appreferId: deviceId,
                signedTransaction: transaction.signedTransaction,
                attributes: attributes,
                restore: false
            ))
            storage.clearSentAttributes(attributes)
            await finish(update)
            let info = await accept(response, for: owner)
            await drainQueue()
            return owner == user ? info : await currentAnswerWithoutNetwork()
        } catch let error as AppReferBillingError where error.isRetryable {
            pause(after: error)
            let durable = queue.add(PendingPurchase(
                transactionId: transaction.id,
                productId: transaction.productId,
                appUserId: owner,
                appreferId: deviceId,
                signedTransaction: transaction.signedTransaction,
                enqueuedAt: now(),
                attempts: Self.countsAsAttempt(error) ? 1 : 0
            ))
            if durable {
                logger.warn("Billing: queued transaction \(transaction.id) for retry (\(error.localizedDescription))")
                await finish(update)
            } else {
                logger.error("Billing: couldn't save transaction \(transaction.id) for retry; leaving it unfinished")
                heldUpdates[transaction.id] = update
            }
            return await answerAfterUploadFailure(error)
        } catch {
            // Rejected as malformed: retrying won't help. StoreKit verified it, so it still
            // counts for its owner; App Store notifications reach the server.
            logger.error("Billing: AppRefer rejected transaction \(transaction.id): \(error.localizedDescription)")
            await finish(update)
            return await answerAfterUploadFailure(error as? AppReferBillingError)
        }
    }

    private func finish(_ update: StoreKitUpdate) async {
        heldUpdates[update.transactionId] = nil
        await update.finish()
    }

    /// The cached server answer merged with this customer's StoreKit purchases, without a
    /// request; the outage fallback when there is no cached answer.
    private func currentAnswerWithoutNetwork() async -> AppReferCustomerInfo {
        guard let user = activeUser() else { return await lockedFallback() }
        if lastServerFetch?.appUserId == user, let cached = storage.cachedCustomerInfo(), cached.appUserId == user {
            return publish(await withPendingLocal(cached.reevaluated(at: now())))
        }
        return await localFallback()
    }

    /// A 401/403/404/409/429 or a server-requested wait doesn't use up a retry.
    private static func countsAsAttempt(_ error: AppReferBillingError) -> Bool {
        !error.isBackoff && error.retryAfter == nil
    }

    /// Pauses the retry queue after a back-off status (doubling from 30 s to 1 h) or for
    /// as long as a `Retry-After` asks.
    private func pause(after error: AppReferBillingError) {
        if error.isBackoff {
            let delay = min(max((drainBackoff?.delay ?? 0) * 2, Self.minBackoff), Self.maxBackoff)
            let wait = min(error.retryAfter ?? delay, Self.maxBackoff)
            drainBackoff = (now().addingTimeInterval(wait), delay)
            logger.warn("Billing: AppRefer answered \(error.localizedDescription); retrying queued purchases in \(Int(wait))s")
        } else if let retryAfter = error.retryAfter {
            let until = now().addingTimeInterval(min(retryAfter, Self.maxBackoff))
            drainBackoff = (max(until, drainBackoff?.until ?? until), drainBackoff?.delay ?? 0)
        }
    }

    /// `AppStore.sync()` then sends every current entitlement to AppRefer as a restore for
    /// the user who asked (captured before the App Store sign-in sheet).
    func restore() async throws -> AppReferCustomerInfo {
        let initiator = activeUser()
        try await storeKit.sync()
        let transactions = await storeKit.currentEntitlements()
        guard !transactions.isEmpty else { return await customerInfo(policy: .fetchCurrent) }

        guard let user = initiator, activeUser() != nil else { return await lockedFallback() }
        await flushPendingIdentifies()
        let deviceId = appreferId()
        var last: BillingCustomerResponse?
        var lastError: AppReferBillingError?
        var paused = false
        for transaction in transactions {
            var entry = PendingPurchase(
                transactionId: transaction.id, productId: transaction.productId, appUserId: user,
                appreferId: deviceId, signedTransaction: transaction.signedTransaction,
                enqueuedAt: now(), attempts: 0, restore: true
            )
            if paused {
                // AppRefer can't take more now: queue the rest of the restore unsent.
                queue.add(entry)
                continue
            }
            do {
                last = try await api.send(.purchase(
                    appUserId: user, appreferId: deviceId,
                    signedTransaction: transaction.signedTransaction, attributes: [:], restore: true
                ))
            } catch let error as AppReferBillingError where error.isRetryable {
                lastError = error
                entry.attempts = Self.countsAsAttempt(error) ? 1 : 0
                queue.add(entry)
                pause(after: error)
                paused = error.isConnectivity || error.isBackoff || error.retryAfter != nil
            } catch {
                lastError = error as? AppReferBillingError
            }
        }
        // AppRefer answered: its answer plus this customer's own (and queued) purchases.
        if let last { return await accept(last, for: user) }
        return await answerAfterUploadFailure(lastError)
    }

    /// Re-sends queued transactions. Stops at the first connectivity failure. A
    /// 401/403/404/409/429 or a `Retry-After` pauses the drain without counting an
    /// attempt, so a server-side setup problem never uses up a purchase's retries.
    func drainQueue() async {
        guard !isDraining, activeUser() != nil else { return }
        isDraining = true
        defer { isDraining = false }
        await processDeferredUpdates()
        await finishSavedHeldUpdates()
        guard !queue.isEmpty else { return }
        if let backoff = drainBackoff, now() < backoff.until { return }

        for dropped in queue.prune(now: now()) {
            logger.error("Billing: gave up resending transaction \(dropped.transactionId) after \(dropped.attempts) attempts")
            if let held = heldUpdates[dropped.transactionId] { await finish(held) }
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
                // Recorded by AppRefer: safe to finish even if the retry copy never saved.
                if let held = heldUpdates[entry.transactionId] { await finish(held) }
                if entry.appUserId == activeUser() { _ = await accept(response, for: entry.appUserId) }
            } catch let error as AppReferBillingError where error.isRetryable {
                pause(after: error)
                if !Self.countsAsAttempt(error) { return }
                queue.recordAttempt(transactionId: entry.transactionId)
                if error.isConnectivity { return }
            } catch {
                queue.remove(transactionId: entry.transactionId)
                if let held = heldUpdates[entry.transactionId] { await finish(held) }
            }
        }
    }

    /// Saves retry copies that failed to save before, then finishes their transactions.
    private func finishSavedHeldUpdates() async {
        guard queue.hasProvisionalEntries || !heldUpdates.isEmpty else { return }
        queue.retryPersistence()
        for (id, update) in heldUpdates where queue.isDurable(transactionId: id) {
            await finish(update)
        }
    }

    private func processDeferredUpdates() async {
        guard !deferredUpdates.isEmpty, activeUser() != nil else { return }
        let updates = deferredUpdates
        let initiators = deferredInitiators
        deferredUpdates = []
        deferredInitiators = [:]
        for update in updates { _ = await process(update, initiator: initiators[update.transactionId]) }
    }

    // MARK: - Purchases

    /// The user starting a purchase and their Apple `appAccountToken` (fetched from
    /// AppRefer if not cached). Capture this before opening the purchase sheet and pass
    /// the user to `process(_:initiator:)`, so a logIn during the sheet can't take the
    /// purchase. The token is nil when AppRefer is unreachable: the purchase still goes ahead.
    func beginPurchase() async -> (initiator: String?, accountToken: UUID?) {
        guard let user = activeUser() else { return (nil, nil) }
        if let token = storage.accountToken(for: user) { return (user, token) }
        _ = try? await fetchFromServer(user, drain: false)
        return (user, storage.accountToken(for: user))
    }

    func accountToken() async -> UUID? {
        await beginPurchase().accountToken
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
    /// Concurrent callers share one flush; an identify added while it ran gets another.
    private func flushPendingIdentifies() async {
        if let running = identifyFlush { await running.value }
        guard !storage.pendingIdentifies.isEmpty else { return }
        if let running = identifyFlush {
            await running.value
            return
        }
        let flush = Task { await self.sendPendingIdentifies() }
        identifyFlush = flush
        await flush.value
        identifyFlush = nil
    }

    private func sendPendingIdentifies() async {
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
