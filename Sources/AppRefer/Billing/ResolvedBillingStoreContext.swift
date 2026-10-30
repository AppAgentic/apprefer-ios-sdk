import Foundation

/// Keeps initial store-context lookup separate from customer access. No grant while it is pending.
final class ResolvedBillingStoreContext: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var detected: BillingEnvironment?

    func resolve(from store: BillingStoreKit, explicit: BillingEnvironment?) async {
        resolve(explicit == nil ? await store.storeEnvironment() : nil)
    }
    func resolve(_ value: BillingEnvironment?) {
        lock.lock(); detected = value; ready = true; lock.unlock()
    }
    var verifiedEnvironment: BillingEnvironment? { lock.lock(); defer { lock.unlock() }; return ready ? detected : nil }
    func select(apiKey: String?, explicit: BillingEnvironment?) -> BillingEnvironment? {
        guard let apiKey else { return explicit }
        if explicit != nil || apiKey.hasPrefix("pk_test_") { return try? BillingEnvironment.select(apiKey: apiKey, explicit: explicit) }
        lock.lock(); defer { lock.unlock() }
        guard ready else { return nil }
        return detected ?? .production
    }
}
