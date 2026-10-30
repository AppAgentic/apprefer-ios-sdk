import Foundation

/// Core of AppReferBilling: identity, server sync, transaction processing, retry queue
/// and the outage fallback. StoreKit purchase UI lives in `AppReferBilling`; everything
/// here goes through `BillingStoreKit` and `BillingAPIClient` so it can be tested.
/// Call-order tickets for reset() and Billing identity calls (logIn/logOut), taken
/// synchronously when each is called, plus the newest ticket of a logIn/logOut that was
/// applied (validated, new user stored or queued in order).
final class BillingIdentityChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var applied = 0
    func take() -> Int { lock.lock(); defer { lock.unlock() }; next += 1; return next }
    func markApplied(_ ticket: Int) { lock.lock(); defer { lock.unlock() }; applied = max(applied, ticket) }
    var latestApplied: Int { lock.lock(); defer { lock.unlock() }; return applied }
}

actor BillingEngine {
    struct Options: Sendable {
        var productEntitlements: [String: [String]] = [:]
        var defaultEntitlement: String?
        var environment: (@Sendable () -> BillingEnvironment?)?
        var automaticScope: AutomaticBillingScope?
        /// How long a server answer counts as fresh for `.cachedOrFetched`.
        var cacheTTL: TimeInterval = 5 * 60
    }

    private var offeringsInvalidated = false
    private var offeringsGeneration = 0
    private var offeringsCache: [String: CachedOfferings] = [:]
    private var offeringsRequest: (UUID, Task<AppReferOfferings, Error>, AppReferBilling.FetchPolicy)?
    func offerings(policy: AppReferBilling.FetchPolicy = .cachedOrFetched) async throws -> AppReferOfferings {
        if let request = offeringsRequest, request.2 == policy || request.2 == .fetchCurrent { return try await request.1.value }
        let id = UUID()
        let generation = offeringsGeneration
        let task = Task { try await self.loadOfferings(policy: policy, generation: generation) }
        offeringsRequest = (id, task, policy)
        defer { if offeringsRequest?.0 == id { offeringsRequest = nil } }
        return try await task.value
    }
    private func loadOfferings(policy: AppReferBilling.FetchPolicy, generation: Int) async throws -> AppReferOfferings {
        guard let user = activeUser(), let bucket = storage.offeringsBucketId() else { throw AppReferBillingError.storage("Billing identity is unreadable") }
        var cached = offeringsCache[user] ?? storage.cachedOfferings(for: user)
        if offeringsInvalidated || policy == .fetchCurrent || cached == nil || now().timeIntervalSince(cached!.fetchedAt) >= 300 {
            do {
                var fields = ["appUserId": user, "bucketId": bucket, "platform": "ios"]
                if let country = await storeKit.storefrontCountry() { fields["country"] = country }
                fields["appVersion"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                let c = cached?.response.context
                let known: [String: String]? = c?.experimentId.flatMap { exp in c?.variantId.map { ["experimentId": exp, "variantId": $0] } }
                let data = try await api.sendRaw(.offerings(body: fields, known: known))
                guard let response = try? JSONDecoder().decode(OfferingsResponse.self, from: data) else { throw AppReferBillingError.invalidResponse }
                cached = CachedOfferings(response: response, fetchedAt: now())
                if generation == offeringsGeneration {
                    offeringsInvalidated = false
                    storage.saveOfferings(cached!, for: user)
                }
            } catch { if cached == nil { throw error as? AppReferBillingError ?? AppReferBillingError.network(error.localizedDescription) } }
        }
        if generation == offeringsGeneration { offeringsCache[user] = cached! }
        return try await cached!.response.resolve { try await self.storeKit.products($0) }
    }
    func refreshOfferingsIfStale() async {
        guard let user = activeUser(), offeringsCache[user] != nil || storage.cachedOfferings(for: user) != nil else { return }
        _ = try? await offerings()
    }
    private func invalidateOfferings() {
        offeringsGeneration += 1
        offeringsInvalidated = true
        offeringsRequest = nil
        for key in offeringsCache.keys { offeringsCache[key]?.fetchedAt = .distantPast }
        if !offeringsCache.isEmpty { Task { _ = try? await self.offerings(policy: .fetchCurrent) } }
    }
    private let api: BillingAPIClient
    private let storage: BillingStorage
    private let queue: PendingPurchaseQueue
    private let rejected: RejectedPurchaseLog
    private let intents: PurchaseIntentStore
    private let storeKit: BillingStoreKit
    private let options: Options
    /// The install device id, or nil while it must not be sent (collection off, after
    /// reset until configure, never configured). Read per request; use `linkableDeviceId(for:)`.
    private let appreferId: @Sendable () -> String?
    /// Advances on every `AppRefer.reset()`.
    private let accountEpoch: @Sendable () -> Int
    /// Whether identify may copy the anonymous customer's install link (the same gate).
    private let linkAllowed: @Sendable () -> Bool
    /// The account epoch when the current Billing user was set (configure, logIn, logOut).
    /// A user set before the last reset belongs to the previous account.
    private var identityEpoch: Int
    /// The epoch `unlinkedUsers` belongs to; a reset forgets them.
    private var unlinkedEpoch: Int
    private let logger: AppReferLogger
    private let onChange: @Sendable (AppReferCustomerInfo) -> Void
    private let now: @Sendable () -> Date

    private var lastPublished: AppReferCustomerInfo?
    private var lastServerFetch: (appUserId: String, at: Date)?
    /// Users whose appreferId/attributes were registered (POST customers) this launch.
    private var registeredUsers = Set<String>()
    /// Of those, the ones registered without a device id.
    private var unlinkedUsers = Set<String>()
    private var updatesTask: Task<Void, Never>?
    private var isDraining = false
    private var migratingUsers = Set<String>()
    /// Retry queue pause after 401/403/404/409/429 (doubling) or a `Retry-After`.
    private var drainBackoff: (until: Date, delay: TimeInterval)?
    /// Transactions whose retry copy isn't on disk yet: left unfinished until it is saved
    /// or AppRefer records them.
    private var heldUpdates: [String: StoreKitUpdate] = [:]
    private var identifyFlush: Task<Void, Never>?
    /// The install device id for a request made for `owner`: only when the gate is open,
    /// `owner` is the current Billing user and that user was set after the last reset
    /// (in this process, or, through the persisted reset marker, in an earlier one).
    /// A purchase or queued entry of a previous account never gets it.
    private func linkableDeviceId(for owner: String?) -> String? {
        let epoch = accountEpoch()
        if epoch != unlinkedEpoch {
            unlinkedUsers.removeAll()
            unlinkedEpoch = epoch
        }
        guard let owner, identityEpoch == epoch, let current = activeUser(), owner == current,
              !storage.resetMarkerHolds(for: current) else { return nil }
        return appreferId()
    }

    /// Called by `AppRefer.reset()`: persists the current Billing user as the previous
    /// account, so the gate stays closed for it after a relaunch. Skipped when a logIn/logOut
    /// called after `reset()` (ticket `resetTicket`, taken when reset() was called) has
    /// already been applied: the write would land on the next account. A logIn/logOut that
    /// threw was never applied, so it never cancels the marker. An anonymous id that logOut()
    /// minted in this process (logOut before reset) is not marked, once: a later reset()
    /// while that user is still current marks them.
    func recordAccountReset(resetTicket: Int? = nil) {
        if let resetTicket, identityChanges.latestApplied > resetTicket { return }
        var explicit: String?
        switch pendingIdentityChanges.last {
        case .logOut?:
            // Will mint a fresh anonymous id for the next account; that uses the exemption.
            mintExemptionUsed = true
            return
        case .logIn(let id)?: explicit = id
        default: break
        }
        guard let current = explicit ?? storage.storedCurrentAppUserId else { return }
        if current == anonymousMintedByLogOut {
            anonymousMintedByLogOut = nil
            return
        }
        try? options.automaticScope?.setUser(current, invalidate: true)
        storage.resetUser = current
    }

    /// Call-order tickets for reset() and logIn/logOut (see `BillingIdentityChanges`).
    nonisolated let identityChanges = BillingIdentityChanges()
    /// The appUserId passed to `AppReferBilling.configure`, if any.
    nonisolated let configuredAppUserId: String?
    /// The anonymous id the last logOut() minted in this process, until a reset() uses the
    /// exemption or logIn runs.
    private var anonymousMintedByLogOut: String?
    /// A reset() already skipped a queued logOut's future id.
    private var mintExemptionUsed = false

    /// Attribution and device signals among the customer attributes.
    static let deviceAttributeKeys: Set<String> = ["$idfa", "$idfv", "$fbAnonId", "$attConsentStatus", "$deviceVersion", "$ip", "$gpsAdId"]
    /// While the install may not be linked, device signals are dropped, never sent later.
    static func sendable(_ attributes: [String: String], linked: Bool) -> [String: String] {
        linked ? attributes : attributes.filter { !deviceAttributeKeys.contains($0.key) }
    }
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
    /// Untagged purchases in `deferredUpdates` waiting because the intents were lost.
    private var lostIntentDeferrals = Set<String>()

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
        accountEpoch: @escaping @Sendable () -> Int = { AppRefer.accountEpoch() },
        linkAllowed: @escaping @Sendable () -> Bool = { AppRefer.installLinkAllowed() },
        logger: AppReferLogger,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping @Sendable (AppReferCustomerInfo) -> Void = { _ in }
    ) {
        self.api = api
        self.storage = storage
        self.queue = queue
        self.rejected = rejected ?? RejectedPurchaseLog(fileURL: storage.directory.appendingPathComponent("rejected_purchases.json"))
        self.intents = intents ?? PurchaseIntentStore(fileURL: storage.directory.appendingPathComponent("purchase_intents.json"), now: now)
        self.storeKit = storeKit
        self.options = options
        self.appreferId = appreferId
        self.accountEpoch = accountEpoch
        self.linkAllowed = linkAllowed
        identityEpoch = accountEpoch()
        unlinkedEpoch = identityEpoch
        configuredAppUserId = appUserId.flatMap { $0.isEmpty ? nil : $0 }
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
        // A different Billing user ends the reset marker.
        _ = storage.resetMarkerHolds(for: storage.storedCurrentAppUserId)
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
        guard let user = storage.currentAppUserId else { return nil }
        do { try options.automaticScope?.setUser(user, resetMarked: storage.resetMarkerHolds(for: user), resetGeneration: storage.automaticResetGeneration) } catch { return nil }
        return user
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
            guard let fresh = storage.resetAnonymousId() else { return false }
            anonymousMintedByLogOut = mintExemptionUsed ? nil : fresh
            mintExemptionUsed = false
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
        // Offerings must never delay the listener, transaction recovery or entitlements.
        Task { await self.refreshOfferingsIfStale() }
        for update in await storeKit.unfinishedTransactions() {
            _ = await process(update)
        }
        // An accepted purchase may already be finished when the process died before
        // committing its context. Only exact, pre-authorized current proofs recover it.
        if let user = activeUser(), let automatic = options.automaticScope {
            for transaction in await storeKit.currentEntitlements() where automatic.recoverProof(user: user, proof: transaction.signedTransaction) != nil {
                _ = await process(StoreKitUpdate(verified: transaction, transactionId: transaction.id, finish: {}), initiator: user)
            }
        }
        clearIntentsLostMarkerIfIdle()
        _ = await customerInfo(policy: .fetchCurrent)
        Task { await self.migrationSync() }
    }

    /// Read-only import. A distinct queue key keeps migration retries separate from
    /// purchase/restore handling and from another user's import of the same proof.
    func migrationSync(forUser: String? = nil) async {
        guard let active = activeUser() else { return }
        let user = forUser ?? active
        let scope = options.environment?()
        if options.environment != nil && scope == nil { return }
        let phase = options.environment == nil ? user : "environment-v3:\(scope!.rawValue):\(user)"
        guard user == active, !storage.migrationSynced(phase),
              migratingUsers.insert(user).inserted else { return }
        defer { migratingUsers.remove(user) }
        if UUID(uuidString: user) != nil {
            if storage.legacyAccountToken(for: user) == nil { registeredUsers.remove(user) }
            _ = try? await fetchFromServer(user, drain: false)
        }
        guard activeUser() == user, options.environment == nil || options.environment?() == scope else { return }
        let open = Set(await storeKit.unfinishedTransactions().map(\.transactionId))
        let transactions = await storeKit.currentEntitlements()
        guard activeUser() == user, options.environment == nil || options.environment?() == scope else { return }
        let deviceId = linkableDeviceId(for: user)
        var durable = true
        for transaction in transactions {
            guard activeUser() == user, options.environment == nil || options.environment?() == scope else { return }
            if open.contains(transaction.id) { durable = false; continue }
            if let token = transaction.appAccountToken, !ownsAccountToken(token, user: user) {
                // Backend may not support legacy ownership yet. Retry after it does.
                if UUID(uuidString: user) == token { durable = false }
                continue // A foreign or unknown token must never be claimed by this user.
            }
            let progress = "\(Data(phase.utf8).base64EncodedString()):\(transaction.id)"
            if storage.isMigrationPurchase(progress) { continue }
            if let existing = queue.entry(transactionId: transaction.id), existing.appUserId == user,
               queue.isDurable(transactionId: transaction.id) {
                if !storage.markMigrationPurchase(progress) { durable = false }
                continue
            }
            switch intents.match(transaction) {
            case .found, .unreadable, .lost: durable = false; continue
            case .none: break
            }
            if transaction.id.isEmpty || transaction.signedTransaction.isEmpty { durable = false; continue }
            let key = "migration:\(Data(user.utf8).base64EncodedString()):\(transaction.id)"
            if queue.isDurable(transactionId: key) {
                if !storage.markMigrationPurchase(progress) { durable = false }
                continue
            }
            let entry = PendingPurchase(
                transactionId: key, productId: transaction.productId, appUserId: user,
                appreferId: deviceId, signedTransaction: transaction.signedTransaction,
                enqueuedAt: now(), attempts: 0, kind: transaction.kind.rawValue,
                accountToken: transaction.appAccountToken
            )
            if !queue.add(entry) || !storage.markMigrationPurchase(progress) { durable = false }
        }
        if durable { storage.markMigrationSynced(phase) }
        await drainQueue()
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
           let cached = scopedCachedInfo(), cached.appUserId == user {
            return publish(await withPendingLocal(cached.reevaluated(at: now())))
        }
        do {
            return try await fetchFromServer(user)
        } catch {
            logger.warn("Billing: customer refresh failed (\(error.localizedDescription)); using StoreKit fallback")
            return await localFallback()
        }
    }

    private func scopedCachedInfo() -> AppReferCustomerInfo? {
        let info = storage.cachedCustomerInfo()
        guard let environment = options.environment else { return info }
        guard let selected = environment(), info?.environment == selected else { return nil }
        return info
    }

    private func fetchFromServer(_ user: String, drain: Bool = true) async throws -> AppReferCustomerInfo {
        await flushPendingIdentifies()
        let attributes = storage.pendingAttributes
        let deviceId = linkableDeviceId(for: user)
        let sent = Self.sendable(attributes, linked: deviceId != nil)
        // Registered without a device id (collection off, reset, before configure): link
        // the install once it's allowed again.
        let needsRegister = !registeredUsers.contains(user) || !attributes.isEmpty || storage.accountToken(for: user) == nil
            || (deviceId != nil && unlinkedUsers.contains(user))
        let response = try await api.send(
            needsRegister
                ? .createCustomer(appUserId: user, appreferId: deviceId, attributes: sent)
                : .getCustomer(appUserId: user)
        )
        if needsRegister {
            registeredUsers.insert(user)
            if deviceId == nil { unlinkedUsers.insert(user) } else { unlinkedUsers.remove(user) }
            storage.clearSentAttributes(attributes)
        }
        let info = await accept(response, for: user)
        if drain { await drainQueue() }
        return info
    }

    /// Stores a server answer and returns what callers should see.
    private func accept(_ response: BillingCustomerResponse, for user: String) async -> AppReferCustomerInfo {
        if let token = response.accountToken { storage.setAccountToken(token, for: response.info.appUserId) }
        storage.setLegacyAccountToken(response.legacyAppAccountToken, for: response.info.appUserId)
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

    /// RevenueCat StoreKit 2 used UUID(appUserId), not AppRefer's random token.
    /// A locally registered foreign owner always wins over this compatibility rule.
    private func ownsAccountToken(_ token: UUID, user: String) -> Bool {
        if let owner = storage.appUserId(forAccountToken: token) { return owner == user }
        return token == storage.accountToken(for: user) || storage.legacyAccountToken(for: user) == token
    }

    private func blocksQueuedToken(_ token: UUID?, user: String) -> Bool {
        guard let token else { return false }
        if let owner = storage.appUserId(forAccountToken: token), owner != user { return true }
        return UUID(uuidString: user) == token && !ownsAccountToken(token, user: user)
    }

    /// This user's verified StoreKit entitlements (see `withPendingLocal`).
    private func ownedTransactions(_ user: String) async -> [StoreTransaction] {
        let queued = Set(queue.entries.filter { $0.appUserId == user }.map(\.transactionId))
        return await storeKit.currentEntitlements().filter {
            ($0.appAccountToken.map { ownsAccountToken($0, user: user) } ?? true) || (queued.contains($0.id) && !blocksQueuedToken($0.appAccountToken, user: user))
        }
    }

    /// AppRefer is reachable, so access comes from it: the user's own server answer, or,
    /// if that request fails, their cached answer merged with only their own StoreKit
    /// purchases. Never the unrestricted device fallback.
    private func reachableAnswer(for user: String) async -> AppReferCustomerInfo {
        if let info = try? await fetchFromServer(user, drain: false) { return info }
        let cached = scopedCachedInfo().flatMap { $0.appUserId == user ? $0.reevaluated(at: now()) : nil }
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
        let cached = scopedCachedInfo().flatMap { $0.appUserId == user ? $0.reevaluated(at: now()) : nil }
        let merged = mergeLocal(into: cached, transactions: transactions, user: user, source: .localFallback)
        return publish(merged)
    }

    private func mergeLocal(
        into server: AppReferCustomerInfo?,
        transactions: [StoreTransaction],
        user: String,
        source: AppReferCustomerInfo.Source
    ) -> AppReferCustomerInfo {
        let selected = options.environment?()
        let scoped = options.environment == nil ? transactions : transactions.filter { selected != nil && $0.environment == selected }
        let base = options.environment == nil || (selected != nil && server?.environment == selected) ? server : nil
        let local = LocalEntitlements.compute(
            transactions: scoped,
            configured: options.productEntitlements,
            learned: storage.learnedEntitlements,
            defaultEntitlement: options.defaultEntitlement,
            now: now()
        )
        let result = LocalEntitlements.merge(server: base, local: local, appUserId: user, now: now(), source: source)
        return AppReferCustomerInfo(appUserId: result.appUserId, entitlements: result.entitlements, activeSubscriptions: result.activeSubscriptions, requestDate: result.requestDate, source: result.source, environment: selected ?? base?.environment)
    }

    @discardableResult
    private func publish(_ original: AppReferCustomerInfo) -> AppReferCustomerInfo {
        var info = original
        if let environment = options.environment {
            let selected = environment()
            if selected == nil || info.environment != selected {
                info = AppReferCustomerInfo(appUserId: info.appUserId, entitlements: EntitlementInfos([:]), activeSubscriptions: [], requestDate: now(), source: info.source, environment: selected)
            }
        }
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
    func process(_ update: StoreKitUpdate, initiator: String? = nil, intent suppliedIntent: PurchaseIntent? = nil) async -> AppReferCustomerInfo {
        // A renewal never uses or consumes an intent, even one the purchase sheet supplied:
        // its owner comes from the initiator, its account token or the current user.
        var intent = (update.verified ?? update.unverifiedPayload)?.isRenewal == true ? nil : suppliedIntent
        guard let transaction = update.verified else {
            let claimed = update.unverifiedPayload
            let entry = AppReferRejectedPurchase(
                transactionId: update.transactionId,
                productId: claimed?.productId ?? "",
                appUserId: initiator ?? activeUser(),
                appreferId: linkableDeviceId(for: initiator ?? activeUser()),
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
        var supportNote: String?
        if intent == nil, initiator == nil {
            switch intents.match(transaction) {
            case .found(let saved): intent = saved
            case .none: break
            case .unreadable where tokenOwner == nil:
                logger.warn("Billing: purchase intents unreadable; transaction \(transaction.id) deferred")
                deferUpdate(update, initiator: nil, intent: nil)
                return await currentAnswerWithoutNetwork()
            case .unreadable: break
            case .lost(let since):
                // Who started it was in the lost file. Wait for them (left unfinished, retried
                // on foreground), then within Google's acknowledgement window give it to
                // whoever is signed in and say so.
                if now() < min(since, transaction.purchaseDate).addingTimeInterval(PurchaseIntentStore.lostIntentsWait) {
                    logger.warn("Billing: purchase intents were lost; transaction \(transaction.id) deferred")
                    deferUpdate(update, initiator: nil, intent: nil)
                    lostIntentDeferrals.insert(update.transactionId)
                    return await currentAnswerWithoutNetwork()
                }
                supportNote = "Purchase intents on this device were unreadable since \(ISO8601DateFormatter().string(from: since)); "
                    + "after waiting 48 hours this purchase was assigned to the signed-in user \(user). Confirm the buyer."
                logger.error("Billing: transaction \(transaction.id): \(supportNote ?? "")")
            }
        }
        let owner = initiator ?? tokenOwner ?? intent?.appUserId ?? user
        // Attributes belong to whoever is signed in now.
        let attributes = owner == user ? storage.pendingAttributes : [:]
        let deviceId = linkableDeviceId(for: owner)
        let sent = Self.sendable(attributes, linked: deviceId != nil)
        do {
            // Never a restore: purchases and Transaction.updates (renewals included) must
            // not move a purchase owned by another app user to whoever is signed in.
            let endpoint = BillingAPIClient.Endpoint.purchase(
                appUserId: owner,
                appreferId: deviceId,
                signedTransaction: transaction.signedTransaction,
                attributes: sent,
                restore: false,
                presentedOfferingContext: intent?.presentedOfferingContext,
                bucketId: intent?.bucketId
            )
            let automatic = options.automaticScope
            let ticket = intent.flatMap { automatic?.recoverIntent($0, verified: transaction) }
                ?? automatic?.recoverProof(user: owner, proof: transaction.signedTransaction)
            let response: BillingCustomerResponse
            if let ticket, let environment = transaction.environment {
                try automatic?.authorizeProof(transaction.signedTransaction, ticket: ticket)
                response = try await sendAuthorizedPurchase(endpoint, ticket: ticket, verifiedEnvironment: environment)
                storage.recordPurchaseEnvironment(transaction.signedTransaction, environment: environment)
                try automatic?.forgetProof(transaction.signedTransaction)
            } else { response = try await api.send(endpoint) }
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
                presentedOfferingContext: intent?.presentedOfferingContext, bucketId: intent?.bucketId,
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
                verifiedByStoreKit: true, reason: error.localizedDescription, rejectedAt: now(),
                supportNote: supportNote
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
        if let intent { try? options.automaticScope?.forgetIntent(intent.id); intents.remove(intent) }
    }

    private func rejectedEntry(from entry: PendingPurchase, reason: String) -> AppReferRejectedPurchase {
        let prefix = "migration:\(Data(entry.appUserId.utf8).base64EncodedString()):"
        let migrationOnly = entry.transactionId.hasPrefix(prefix)
        return AppReferRejectedPurchase(
            transactionId: migrationOnly ? String(entry.transactionId.dropFirst(prefix.count)) : entry.transactionId,
            productId: entry.productId, appUserId: entry.appUserId,
            appreferId: entry.appreferId, signedTransaction: entry.signedTransaction,
            accountToken: entry.accountToken, kind: entry.kind ?? heldUpdates[entry.transactionId]?.verified?.kind.rawValue,
            verifiedByStoreKit: true, reason: reason, rejectedAt: now(),
            migrationOnly: migrationOnly
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
        if lastServerFetch?.appUserId == user, let cached = scopedCachedInfo(), cached.appUserId == user {
            return publish(await withPendingLocal(cached.reevaluated(at: now())))
        }
        return await localFallback()
    }

    /// A 401/403/404/409/429 or a server-requested wait doesn't use up a retry.
    private static func countsAsAttempt(_ error: AppReferBillingError) -> Bool {
        if case .environmentMismatch = error { return false }
        return !error.isBackoff && error.retryAfter == nil
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
        let deviceId = linkableDeviceId(for: user)
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
        let preserveScopedProofs = options.environment != nil
        let dropped = queue.prune(now: now(), eligible: { _ in !preserveScopedProofs }) { entry in
            rejected.add(rejectedEntry(from: entry, reason: "not recorded after \(entry.attempts) attempts"))
        }
        for entry in dropped {
            logger.error("Billing: gave up resending transaction \(entry.transactionId) after \(entry.attempts) attempts; kept in the rejected list")
        }
        for entry in queue.entries {
            let automaticTicket = entry.restore == true || entry.transactionId.hasPrefix("migration:") ? nil
                : options.automaticScope?.recoverProof(user: entry.appUserId, proof: entry.signedTransaction)
            if automaticTicket == nil, options.environment != nil, let bound = storage.purchaseEnvironment(entry.signedTransaction), bound != options.environment?() { continue }
            do {
                // A queued device id is sent only while linking is allowed now (collection
                // on, configured since the last reset) and only for the current account.
                let endpoint = BillingAPIClient.Endpoint.purchase(
                    appUserId: entry.appUserId, appreferId: linkableDeviceId(for: entry.appUserId) == nil ? nil : entry.appreferId,
                    signedTransaction: entry.signedTransaction, attributes: [:],
                    restore: entry.restore == true,
                    presentedOfferingContext: entry.presentedOfferingContext,
                    bucketId: entry.bucketId
                )
                let response: BillingCustomerResponse
                if let automaticTicket {
                    response = try await sendAuthorizedPurchase(endpoint, ticket: automaticTicket, verifiedEnvironment: storage.purchaseEnvironment(entry.signedTransaction))
                    try options.automaticScope?.forgetProof(entry.signedTransaction)
                } else { response = try await api.send(endpoint) }
                queue.remove(transactionId: entry.transactionId)
                drainBackoff = nil
                // Recorded by AppRefer: safe to finish even if the retry copy never saved.
                if let held = heldUpdates[entry.transactionId] { await finish(held) }
                if entry.appUserId == activeUser() { _ = await accept(response, for: entry.appUserId) }
            } catch AppReferBillingError.environmentMismatch(let actual) {
                storage.recordPurchaseEnvironment(entry.signedTransaction, environment: actual)
                continue
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

    /// Authorization was persisted before upload. A mismatch may redirect this exact
    /// request, but only an owned, generation-current answer can change read scope.
    private func sendAuthorizedPurchase(_ endpoint: BillingAPIClient.Endpoint, ticket: AutomaticBillingScope.Ticket, verifiedEnvironment: BillingEnvironment?) async throws -> BillingCustomerResponse {
        guard options.automaticScope?.isCurrent(ticket) == true else { throw AppReferBillingError.invalidResponse }
        let response: BillingCustomerResponse
        if let verifiedEnvironment {
            response = try await api.sendPurchaseInEnvironment(endpoint, environment: verifiedEnvironment, expectedKey: ticket.key)
        } else {
            do {
                guard let selected = options.environment?() else { throw AppReferBillingError.invalidResponse }
                response = try await api.sendPurchaseInEnvironment(endpoint, environment: selected, expectedKey: ticket.key)
            }
            catch AppReferBillingError.environmentMismatch(let actual) {
                response = try await api.sendPurchaseInEnvironment(endpoint, environment: actual, expectedKey: ticket.key)
            }
        }
        guard let environment = response.info.environment,
              try options.automaticScope?.commit(ticket, environment: environment, owner: response.info.appUserId) == true else { throw AppReferBillingError.invalidResponse }
        return response
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
        guard activeUser() != nil else { return }
        guard !deferredUpdates.isEmpty else {
            // The marker may only now be old enough to clear.
            clearIntentsLostMarkerIfIdle()
            return
        }
        let updates = deferredUpdates
        let initiators = deferredInitiators
        let savedIntents = deferredIntents
        deferredUpdates = []
        deferredInitiators = [:]
        deferredIntents = [:]
        lostIntentDeferrals = []
        for update in updates {
            _ = await process(update, initiator: initiators[update.transactionId], intent: savedIntents[update.transactionId])
        }
        clearIntentsLostMarkerIfIdle()
    }

    /// The lost-intents marker goes once no purchase is waiting for its owner and it is at
    /// least `lostIntentsWait` old, so a slow Ask to Buy purchase arriving later still waits.
    private func clearIntentsLostMarkerIfIdle() {
        guard deferredUpdates.isEmpty, lostIntentDeferrals.isEmpty,
              case .lost(let since) = intents.lostMarker.state,
              now() >= since.addingTimeInterval(PurchaseIntentStore.lostIntentsWait) else { return }
        intents.lostMarker.clear()
    }

    // MARK: - Purchases

    /// Saves who is starting a purchase, with their Apple `appAccountToken` (fetched from
    /// AppRefer if not cached), before the purchase sheet opens. Pass the intent to
    /// `process(_:initiator:intent:)`, so a logIn during the sheet can't take the purchase;
    /// a purchase delivered later (Ask to Buy, restart, user switch) finds it on disk. The
    /// token is nil when AppRefer is unreachable: the purchase still goes ahead. Throws
    /// `purchaseIntentNotSaved` when the intent can't be saved: the sheet must not open.
    func beginPurchase(productId: String, context: PresentedOfferingContext? = nil) async throws -> PurchaseIntent {
        guard let user = activeUser() else { throw AppReferBillingError.purchaseIntentNotSaved }
        let epoch = accountEpoch()
        let identity = identityChanges.latestApplied
        if storage.accountToken(for: user) == nil { _ = try? await fetchFromServer(user, drain: false) }
        _ = await api.awaitKey()
        guard activeUser() == user, epoch == accountEpoch(), identity == identityChanges.latestApplied else { throw AppReferBillingError.purchaseIntentNotSaved }
        let intent = PurchaseIntent(
            presentedOfferingContext: context, bucketId: context == nil ? nil : storage.offeringsBucketId(), appUserId: user, productId: productId, accountToken: storage.accountToken(for: user), startedAt: now()
        )
        guard intents.add(intent) else {
            logger.error("Billing: couldn't save the purchase intent; not opening the purchase sheet")
            throw AppReferBillingError.purchaseIntentNotSaved
        }
        if let ticket = options.automaticScope?.capture(user: user) {
            do { try options.automaticScope?.authorizeIntent(intent, ticket: ticket) }
            catch { intents.remove(intent); throw AppReferBillingError.purchaseIntentNotSaved }
        }
        return intent
    }

    /// The purchase sheet closed without a purchase (cancelled or failed for good).
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

    /// `ticket`: taken by `AppReferBilling.logIn` when it was called (nil takes one now).
    func logIn(_ appUserId: String, ticket: Int? = nil) async throws -> AppReferCustomerInfo {
        let ticket = ticket ?? identityChanges.take()
        guard Self.isValid(appUserId), !BillingStorage.isAnonymous(appUserId) else {
            throw AppReferBillingError.invalidAppUserId
        }
        // The app is saying who the user is now, even when it is the same id.
        if let user = storage.currentAppUserId { try options.automaticScope?.setUser(user, invalidate: true) }
        storage.resetUser = nil
        anonymousMintedByLogOut = nil
        mintExemptionUsed = false
        pendingIdentityChanges.append(.logIn(appUserId))
        // Stored now (or queued in order while protected data is unavailable): only then
        // does it count as an identity change for a reset() called before it.
        _ = activeUser()
        identityChanges.markApplied(ticket)
        identityEpoch = accountEpoch()
        invalidateOfferings()
        let info = await customerInfo(policy: .fetchCurrent)
        Task { await self.migrationSync(forUser: appUserId) }
        return info
    }

    func logOut(ticket: Int? = nil) async -> AppReferCustomerInfo {
        let ticket = ticket ?? identityChanges.take()
        if let user = storage.currentAppUserId { try? options.automaticScope?.setUser(user, invalidate: true) }
        storage.resetUser = nil
        pendingIdentityChanges.append(.logOut)
        _ = activeUser()
        identityChanges.markApplied(ticket)
        identityEpoch = accountEpoch()
        invalidateOfferings()
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
                // link: false while the gate is closed (or the current Billing user is the
                // one from before the last reset), so the server never copies the
                // anonymous customer's install link to the signed-in one.
                let link = linkAllowed() && !storage.resetMarkerHolds(for: activeUser())
                let automaticTicket = options.automaticScope?.capture(user: pending.appUserId)
                let response = try await api.send(.identify(anonymousId: pending.anonymousId, appUserId: pending.appUserId, link: link))
                if let automaticTicket { try options.automaticScope?.inheritConfirmedAnonymous(pending.anonymousId, ticket: automaticTicket, owner: response.info.appUserId) }
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
