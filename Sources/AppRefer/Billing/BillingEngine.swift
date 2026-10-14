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
    private let rejected: RejectedPurchaseLog
    private let intents: PurchaseIntentStore
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
    private var deferredIntents: [String: PurchaseIntent] = [:]

    init(
        api: BillingAPIClient,
        storage: BillingStorage,
        queue: PendingPurchaseQueue,
        rejected: RejectedPurchaseLog? = nil,
        intents: PurchaseIntentStore? = nil,
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
        self.rejected = rejected ?? RejectedPurchaseLog(fileURL: storage.directory.appendingPathComponent("rejected_purchases.json"))
        self.intents = intents ?? PurchaseIntentStore(fileURL: storage.directory.appendingPathComponent("purchase_intents.json"))
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
        let transactions = await ownedTransactions(info.appUserId)
        guard !transactions.isEmpty else { return info }
        return mergeLocal(into: info, transactions: transactions, user: info.appUserId, source: info.source)
    }

    /// This user's verified StoreKit entitlements (see `withPendingLocal`).
    private func ownedTransactions(_ user: String) async -> [StoreTransaction] {
        let token = storage.accountToken(for: user)
        let queued = Set(queue.entries.filter { $0.appUserId == user }.map(\.transactionId))
        return await storeKit.currentEntitlements().filter {
            $0.appAccountToken == nil || $0.appAccountToken == token || queued.contains($0.id)
        }
    }

    /// AppRefer is reachable, so access comes from it: the user's own server answer, or,
    /// if that request fails, their cached answer merged with only their own StoreKit
    /// purchases. Never the unrestricted device fallback.
    private func reachableAnswer(for user: String) async -> AppReferCustomerInfo {
        if let info = try? await fetchFromServer(user, drain: false) { return info }
        let cached = storage.cachedCustomerInfo().flatMap { $0.appUserId == user ? $0.reevaluated(at: now()) : nil }
        let merged = mergeLocal(
            into: cached, transactions: await ownedTransactions(user), user: user,
            source: cached?.source ?? .localFallback
        )
        return publish(merged)
    }

    /// Before first unlock: the user is unknown, so nothing is sent, cached or published.
    /// Verified StoreKit entitlements still answer.
    private func lockedFallback() async -> AppReferCustomerInfo {
        mergeLocal(into: nil, transactions: await storeKit.currentEntitlements(), user: "", source: .localFallback)
    }

    /// After a purchase upload failed, for any reason (a network error too): one customer
    /// fetch decides, merged with this customer's own StoreKit purchases
    /// (`withPendingLocal`). Only when that fails as well (a total outage) does every
    /// verified purchase on the device unlock.
    private func answerAfterUploadFailure() async -> AppReferCustomerInfo {
        if let user = activeUser(), let info = try? await fetchFromServer(user, drain: false) {
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
    /// A transaction AppRefer refuses for good, or StoreKit can't verify, is saved to the
    /// rejected list first (see `secureRejected`).
    ///
    /// `initiator` is the app user who started the purchase (captured before the account
    /// token was fetched and the sheet opened) and `intent` the intent saved for it.
    /// Listener updates have neither: they belong to the user whose account token they
    /// carry, else the user whose saved intent matches (see `PurchaseIntentStore.match`),
    /// else the current user. While the intents can't be read, a delivery that needs them
    /// is left unfinished and retried rather than given to the current user.
    func process(_ update: StoreKitUpdate, initiator: String? = nil, intent: PurchaseIntent? = nil) async -> AppReferCustomerInfo {
        guard let transaction = update.verified else {
            let claimed = update.unverifiedPayload
            let entry = AppReferRejectedPurchase(
                transactionId: update.transactionId,
                productId: claimed?.productId ?? "",
                appUserId: initiator ?? activeUser(),
                appreferId: appreferId(),
                signedTransaction: claimed?.signedTransaction,
                accountToken: claimed?.appAccountToken,
                kind: claimed?.kind.rawValue,
                verifiedByStoreKit: false,
                reason: AppReferBillingError.unverifiedTransaction.localizedDescription,
                rejectedAt: now()
            )
            if await secureRejected(entry, update: update) {
                logger.error("Billing: unverified transaction \(update.transactionId) kept in the rejected list; no access granted")
                dropIntent(intent)
            }
            return await currentAnswerWithoutNetwork()
        }

        guard let user = activeUser() else {
            // Before first unlock: whose purchase this is can't be read. Keep it
            // unfinished and send it once the identity is readable.
            logger.warn("Billing: protected data unavailable; transaction \(transaction.id) deferred")
            deferUpdate(update, initiator: initiator, intent: intent)
            return await lockedFallback()
        }
        let tokenOwner = transaction.appAccountToken.flatMap(storage.appUserId(forAccountToken:))
        var intent = intent
        if intent == nil, initiator == nil {
            switch intents.match(transaction) {
            case .found(let saved): intent = saved
            case .none: break
            case .unreadable where tokenOwner == nil:
                logger.warn("Billing: purchase intents unreadable; transaction \(transaction.id) deferred")
                deferUpdate(update, initiator: nil, intent: nil)
                return await currentAnswerWithoutNetwork()
            case .unreadable: break
            }
        }
        let owner = initiator ?? tokenOwner ?? intent?.appUserId ?? user
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
            rejected.remove(transactionId: transaction.id)
            dropIntent(intent)
            let info = await accept(response, for: owner)
            await drainQueue()
            if owner == user { return info }
            // Someone else's purchase: the signed-in user still gets only their own access.
            guard let current = activeUser() else { return await lockedFallback() }
            return await reachableAnswer(for: current)
        } catch let error as AppReferBillingError where error.isRetryable {
            pause(after: error)
            let durable = queue.add(PendingPurchase(
                transactionId: transaction.id,
                productId: transaction.productId,
                appUserId: owner,
                appreferId: deviceId,
                signedTransaction: transaction.signedTransaction,
                enqueuedAt: now(),
                attempts: Self.countsAsAttempt(error) ? 1 : 0,
                kind: transaction.kind.rawValue,
                accountToken: transaction.appAccountToken
            ))
            if durable {
                logger.warn("Billing: queued transaction \(transaction.id) for retry (\(error.localizedDescription))")
                await finish(update)
                dropIntent(intent)
            } else {
                logger.error("Billing: couldn't save transaction \(transaction.id) for retry; leaving it unfinished")
                heldUpdates[transaction.id] = update
            }
            return await answerAfterUploadFailure()
        } catch {
            // Rejected as malformed: retrying won't help. StoreKit verified it, so it still
            // counts for its owner; App Store notifications reach the server.
            logger.error("Billing: AppRefer rejected transaction \(transaction.id): \(error.localizedDescription)")
            let entry = AppReferRejectedPurchase(
                transactionId: transaction.id, productId: transaction.productId, appUserId: owner,
                appreferId: deviceId, signedTransaction: transaction.signedTransaction,
                accountToken: transaction.appAccountToken, kind: transaction.kind.rawValue,
                verifiedByStoreKit: true, reason: error.localizedDescription, rejectedAt: now()
            )
            if await secureRejected(entry, update: update) { dropIntent(intent) }
            return await answerAfterUploadFailure()
        }
    }

    private func deferUpdate(_ update: StoreKitUpdate, initiator: String?, intent: PurchaseIntent?) {
        if !deferredUpdates.contains(where: { $0.transactionId == update.transactionId }) {
            deferredUpdates.append(update)
        }
        if let initiator { deferredInitiators[update.transactionId] = initiator }
        if let intent { deferredIntents[update.transactionId] = intent }
    }

    /// Saves a purchase AppRefer won't take to the rejected list, and only once that copy
    /// is on disk finishes its transaction. A consumable is never finished: StoreKit
    /// offers it again at the next launch, when it is sent again. Until the copy is saved
    /// nothing is finished, so StoreKit delivers it again. Returns whether it is saved.
    private func secureRejected(_ entry: AppReferRejectedPurchase, update: StoreKitUpdate?) async -> Bool {
        guard rejected.add(entry) else {
            logger.error("Billing: couldn't save rejected transaction \(entry.transactionId); leaving it unfinished")
            return false
        }
        if let update {
            if entry.kind == StoreTransaction.Kind.consumable.rawValue {
                heldUpdates[update.transactionId] = nil
            } else {
                await finish(update)
            }
        }
        return true
    }

    private func dropIntent(_ intent: PurchaseIntent?) {
        if let intent { intents.remove(intent) }
    }

    private func rejectedEntry(from entry: PendingPurchase, reason: String) -> AppReferRejectedPurchase {
        AppReferRejectedPurchase(
            transactionId: entry.transactionId, productId: entry.productId, appUserId: entry.appUserId,
            appreferId: entry.appreferId, signedTransaction: entry.signedTransaction,
            accountToken: entry.accountToken, kind: entry.kind ?? heldUpdates[entry.transactionId]?.verified?.kind.rawValue,
            verifiedByStoreKit: true, reason: reason, rejectedAt: now()
        )
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
    /// the user who asked (captured before the App Store sign-in sheet), followed by
    /// rejected-list purchases StoreKit no longer lists (finished or consumable ones).
    func restore() async throws -> AppReferCustomerInfo {
        let initiator = activeUser()
        try await storeKit.sync()
        let transactions = await storeKit.currentEntitlements()
        let listed = Set(transactions.map(\.id))
        let archived = rejected.entries.filter {
            !($0.signedTransaction ?? "").isEmpty && !listed.contains($0.transactionId)
        }
        guard !transactions.isEmpty || !archived.isEmpty else { return await customerInfo(policy: .fetchCurrent) }

        guard let user = initiator, activeUser() != nil else { return await lockedFallback() }
        await flushPendingIdentifies()
        let deviceId = appreferId()
        var last: BillingCustomerResponse?
        var paused = false
        for transaction in transactions {
            var entry = PendingPurchase(
                transactionId: transaction.id, productId: transaction.productId, appUserId: user,
                appreferId: deviceId, signedTransaction: transaction.signedTransaction,
                enqueuedAt: now(), attempts: 0, restore: true,
                kind: transaction.kind.rawValue, accountToken: transaction.appAccountToken
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
                rejected.remove(transactionId: transaction.id)
            } catch let error as AppReferBillingError where error.isRetryable {
                entry.attempts = Self.countsAsAttempt(error) ? 1 : 0
                queue.add(entry)
                pause(after: error)
                paused = error.isConnectivity || error.isBackoff || error.retryAfter != nil
            } catch {
                logger.error("Billing: AppRefer rejected restored transaction \(transaction.id): \(error.localizedDescription)")
                // For support; StoreKit still lists it, so there's nothing to finish.
                _ = await secureRejected(rejectedEntry(from: entry, reason: error.localizedDescription), update: nil)
            }
        }
        var recordedConsumables = Set<String>()
        for entry in archived where !paused {
            do {
                last = try await api.send(.purchase(
                    appUserId: user, appreferId: deviceId,
                    signedTransaction: entry.signedTransaction ?? "", attributes: [:], restore: true
                ))
                rejected.remove(transactionId: entry.transactionId)
                if entry.kind == StoreTransaction.Kind.consumable.rawValue { recordedConsumables.insert(entry.transactionId) }
            } catch let error as AppReferBillingError where error.isRetryable {
                // Stays in the rejected list for the next restore.
                pause(after: error)
                paused = error.isConnectivity || error.isBackoff || error.retryAfter != nil
            } catch {
                logger.error("Billing: AppRefer rejected archived transaction \(entry.transactionId) again: \(error.localizedDescription)")
            }
        }
        // A consumable left unfinished can be finished now that AppRefer recorded it.
        if !recordedConsumables.isEmpty {
            for update in await storeKit.unfinishedTransactions() where recordedConsumables.contains(update.transactionId) {
                await finish(update)
            }
        }
        // AppRefer answered: its answer plus this customer's own (and queued) purchases.
        if let last { return await accept(last, for: user) }
        return await answerAfterUploadFailure()
    }

    /// Purchases kept in the rejected list (see `AppReferBilling.rejectedPurchases()`).
    func rejectedPurchases() -> [AppReferRejectedPurchase] {
        rejected.entries
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

        // Only saved entries are pruned, and their transactions were finished when they
        // saved; an unsaved one stays held until it is saved or AppRefer records it. Each
        // leaves the queue only once its copy is in the rejected list.
        let dropped = queue.prune(now: now()) { entry in
            rejected.add(rejectedEntry(from: entry, reason: "not recorded after \(entry.attempts) attempts"))
        }
        for entry in dropped {
            logger.error("Billing: gave up resending transaction \(entry.transactionId) after \(entry.attempts) attempts; kept in the rejected list")
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
                // Leaves the queue only once its copy is in the rejected list.
                let archived = rejectedEntry(from: entry, reason: error.localizedDescription)
                guard await secureRejected(archived, update: heldUpdates[entry.transactionId]) else { continue }
                queue.remove(transactionId: entry.transactionId)
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
        let savedIntents = deferredIntents
        deferredUpdates = []
        deferredInitiators = [:]
        deferredIntents = [:]
        for update in updates {
            _ = await process(update, initiator: initiators[update.transactionId], intent: savedIntents[update.transactionId])
        }
    }

    // MARK: - Purchases

    /// Saves who is starting a purchase, with their Apple `appAccountToken` (fetched from
    /// AppRefer if not cached), before the purchase sheet opens. Pass the intent to
    /// `process(_:initiator:intent:)`, so a logIn during the sheet can't take the purchase;
    /// a purchase delivered later (Ask to Buy, restart, user switch) finds it on disk. The
    /// token is nil when AppRefer is unreachable: the purchase still goes ahead. Throws
    /// `purchaseIntentNotSaved` when the intent can't be saved: the sheet must not open.
    func beginPurchase(productId: String) async throws -> PurchaseIntent {
        guard let user = activeUser() else { throw AppReferBillingError.purchaseIntentNotSaved }
        if storage.accountToken(for: user) == nil { _ = try? await fetchFromServer(user, drain: false) }
        let intent = PurchaseIntent(
            appUserId: user, productId: productId, accountToken: storage.accountToken(for: user), startedAt: now()
        )
        guard intents.add(intent) else {
            logger.error("Billing: couldn't save the purchase intent; not opening the purchase sheet")
            throw AppReferBillingError.purchaseIntentNotSaved
        }
        return intent
    }

    /// The purchase sheet closed without a purchase (cancelled or failed).
    func endPurchase(_ intent: PurchaseIntent) {
        dropIntent(intent)
    }

    func accountToken() async -> UUID? {
        guard let user = activeUser() else { return nil }
        if let token = storage.accountToken(for: user) { return token }
        _ = try? await fetchFromServer(user, drain: false)
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
