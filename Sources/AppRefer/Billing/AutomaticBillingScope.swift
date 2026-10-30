import Foundation
import CryptoKit

/// Durable authorization for caller-initiated purchases. A stored receipt alone is never
/// permission to change the active environment. Identity remains owned by BillingEngine.
final class AutomaticBillingScope: @unchecked Sendable {
    struct Ticket: Sendable {
        let user: String
        let key: String
        fileprivate let generation: UUID
        fileprivate let resetEpoch: Int
    }
    private struct Authorization: Codable {
        let context: String
        let generation: UUID
        var intent: String? = nil
        var proof: String? = nil
    }
    private struct Document: Codable {
        var user: String?
        var resetMarked: Bool?
        var resetGeneration: String?
        var generation = UUID()
        var environments: [String: BillingEnvironment] = [:]
        var intents: [String: Authorization] = [:]
        var proofs: [String: Authorization] = [:]
    }
    private let lock = NSLock()
    private let file: URL
    private let apiKey: @Sendable () -> String?
    private let explicit: BillingEnvironment?
    private let resetEpoch: @Sendable () -> Int
    private var observedResetEpoch: Int
    private var document: Document
    private var usable = true
    private var corrupt = false
    private var committedThisLaunch = Set<String>()

    init(directory: URL, apiKey: @escaping @Sendable () -> String?, explicit: BillingEnvironment?, resetEpoch: @escaping @Sendable () -> Int = { 0 }) {
        file = directory.appendingPathComponent("automatic-environments-v1.json")
        self.apiKey = apiKey
        self.explicit = explicit
        self.resetEpoch = resetEpoch
        observedResetEpoch = resetEpoch()
        document = Document()
        usable = false
        _ = reloadIfNeeded()

    }

    /// Called by the identity-owning actor, including explicit reset/same-id login.
    /// Confirmed contexts stay partitioned; purchase capabilities cannot cross a reset.
    func setUser(_ user: String, invalidate: Bool = false, resetMarked: Bool = false, resetGeneration: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        _ = reloadIfNeeded()
        observeReset()
        guard usable else { throw AppReferBillingError.storage("Automatic billing state unavailable") }
        if document.user != user || invalidate || document.resetGeneration != resetGeneration || (resetMarked && document.resetMarked != true) {
            var next = document
            next.user = user; next.resetMarked = resetMarked; next.resetGeneration = resetGeneration; next.generation = UUID()
            next.intents.removeAll(); next.proofs.removeAll()
            try save(next)
        } else if document.resetMarked == true && !resetMarked {
            var next = document; next.resetMarked = false; try save(next)
        }
    }

    func capture(user: String) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        _ = reloadIfNeeded()
        observeReset()
        guard usable, explicit == nil, document.user == user,
              let key = apiKey(), !key.isEmpty, !key.hasPrefix("pk_test_") else { return nil }
        return Ticket(user: user, key: key, generation: document.generation, resetEpoch: resetEpoch())
    }
    private func current(_ ticket: Ticket) -> Bool {
        reloadIfNeeded() && explicit == nil && apiKey() == ticket.key && document.user == ticket.user && document.generation == ticket.generation && resetEpoch() == ticket.resetEpoch
    }
    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }; return current(ticket)
    }
    func select(base: BillingEnvironment?, verifiedStoreEnvironment: BillingEnvironment?) -> BillingEnvironment? {
        lock.lock(); defer { lock.unlock() }
        _ = reloadIfNeeded()
        observeReset()
        guard let key = apiKey() else { return base }
        if explicit != nil || key.hasPrefix("pk_test_") { return base }
        guard usable, let user = document.user else { return base }
        let id = context(user, key)
        if committedThisLaunch.contains(id) { return document.environments[id] }
        if let verifiedStoreEnvironment { return verifiedStoreEnvironment }
        guard base != nil else { return nil }
        return document.environments[id] ?? base
    }
    func environment(user: String) -> BillingEnvironment? {
        lock.lock(); defer { lock.unlock() }
        guard reloadIfNeeded(), document.user == user, let key = apiKey() else { return nil }
        return document.environments[context(user, key)]
    }
    func authorizeIntent(_ intent: PurchaseIntent, ticket: Ticket) throws {
        lock.lock(); defer { lock.unlock() }
        guard current(ticket), intent.appUserId == ticket.user else { throw AppReferBillingError.invalidResponse }
        var next = document
        next.intents[intent.id.uuidString] = Authorization(context: context(ticket.user, ticket.key), generation: ticket.generation)
        try save(next)
    }
    /// Only call with a StoreKit-verified transaction, not a decoded queue payload.
    func recoverIntent(_ intent: PurchaseIntent, verified transaction: StoreTransaction) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard let ticket = captureLocked(user: intent.appUserId),
              let authorization = document.intents[intent.id.uuidString], matches(authorization, ticket),
              authorization.proof == nil || authorization.proof == hash(transaction.signedTransaction),
              !transaction.isRenewal, transaction.productId == intent.productId,
              transaction.purchaseDate >= intent.startedAt.addingTimeInterval(-300),
              intent.accountToken == nil || intent.accountToken == transaction.appAccountToken else { return nil }
        return ticket
    }
    func authorizeProof(_ proof: String, ticket: Ticket, intent: PurchaseIntent? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard current(ticket) else { throw AppReferBillingError.invalidResponse }
        var next = document
        let previous = next.proofs[hash(proof)]
        var authorization = Authorization(context: context(ticket.user, ticket.key), generation: ticket.generation, intent: previous.flatMap { matches($0, ticket) ? $0.intent : nil })
        if let intent {
            let id = intent.id.uuidString
            guard var pending = next.intents[id], matches(pending, ticket), pending.proof == nil || pending.proof == hash(proof) else { throw AppReferBillingError.invalidResponse }
            pending.proof = hash(proof); next.intents[id] = pending; authorization.intent = id
        }
        next.proofs[hash(proof)] = authorization
        try save(next)
    }
    func recoverProof(user: String, proof: String) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard let ticket = captureLocked(user: user), let authorization = document.proofs[hash(proof)], matches(authorization, ticket) else { return nil }
        return ticket
    }
    func forgetIntent(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var next = document; next.intents.removeValue(forKey: id.uuidString); try save(next)
    }
    func forgetProof(_ proof: String) throws {
        lock.lock(); defer { lock.unlock() }
        var next = document; next.proofs.removeValue(forKey: hash(proof)); try save(next)
    }
    /// Called after a server answer has confirmed both environment and captured owner.
    @discardableResult func commit(_ ticket: Ticket, environment: BillingEnvironment, owner: String, acceptedProof: String? = nil) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current(ticket), owner == ticket.user else { return false }
        var next = document; next.environments[context(ticket.user, ticket.key)] = environment
        if let acceptedProof {
            if let id = next.proofs[hash(acceptedProof)]?.intent { next.intents.removeValue(forKey: id) }
            next.proofs.removeValue(forKey: hash(acceptedProof))
        }
        try save(next); committedThisLaunch.insert(context(ticket.user, ticket.key)); return true
    }
    func inheritConfirmedAnonymous(_ anonymous: String, ticket: Ticket, owner: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard BillingStorage.isAnonymous(anonymous), owner == ticket.user, current(ticket) else { return }
        let target = context(ticket.user, ticket.key)
        guard document.environments[target] == nil, let inherited = document.environments[context(anonymous, ticket.key)] else { return }
        var next = document; next.environments[target] = inherited
        try save(next); committedThisLaunch.insert(target)
    }
    /// Protected data and transient disk errors may recover after unlock. Reload the
    /// authoritative atomic file before accepting any capability; malformed data stays
    /// fail-closed and is never overwritten with an invented authorization document.
    private func reloadIfNeeded() -> Bool {
        if usable { return true }
        guard !corrupt else { return false }
        do {
            let data = try Data(contentsOf: file)
            guard let decoded = try? JSONDecoder().decode(Document.self, from: data) else { corrupt = true; return false }
            document = decoded; usable = true; return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            document = Document(); usable = true; return true
        } catch { return false }
    }
    private func observeReset() {
        let epoch = resetEpoch()
        guard epoch != observedResetEpoch else { return }
        var next = document; next.generation = UUID(); next.intents.removeAll(); next.proofs.removeAll()
        do { try save(next); observedResetEpoch = epoch } catch { usable = false }
    }
    private func captureLocked(user: String) -> Ticket? {
        _ = reloadIfNeeded()
        observeReset()
        guard usable, explicit == nil, document.user == user,
              let key = apiKey(), !key.isEmpty, !key.hasPrefix("pk_test_") else { return nil }
        return Ticket(user: user, key: key, generation: document.generation, resetEpoch: resetEpoch())
    }
    private func matches(_ authorization: Authorization, _ ticket: Ticket) -> Bool {
        authorization.context == context(ticket.user, ticket.key) && authorization.generation == ticket.generation
    }
    private func context(_ user: String, _ key: String) -> String { hash(user + "\u{0}" + key) }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func save(_ next: Document) throws {
        guard usable else { throw AppReferBillingError.storage("Automatic billing state unavailable") }
        do {
            try ProtectedBillingState.write(JSONEncoder().encode(next), to: file)
            document = next
        } catch { usable = false; throw AppReferBillingError.storage("Could not save automatic billing state") }
    }
}
