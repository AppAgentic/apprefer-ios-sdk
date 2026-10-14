import Foundation

/// A StoreKit purchase AppRefer refused for good (400/413/422), that StoreKit could not
/// verify, or that the retry queue gave up on. Saved on the device before the transaction
/// is finished (consumables are never finished), so support can recover it and
/// `AppReferBilling.restorePurchases()` can send it again.
public struct AppReferRejectedPurchase: Codable, Equatable, Sendable {
    /// StoreKit transaction id.
    public let transactionId: String
    /// Empty when StoreKit gave none.
    public let productId: String
    /// The customer it was sent for; nil when it never got that far.
    public let appUserId: String?
    public let appreferId: String?
    /// The StoreKit JWS (`signedTransaction`); nil when StoreKit gave none.
    public let signedTransaction: String?
    /// The purchase's `appAccountToken`.
    public let accountToken: UUID?
    /// `autoRenewable`, `nonRenewable`, `consumable` or `nonConsumable`, when known.
    public let kind: String?
    /// False when StoreKit could not verify the signature.
    public let verifiedByStoreKit: Bool
    /// Why AppRefer did not take it.
    public let reason: String
    public let rejectedAt: Date
}

/// Where a durable list is kept (the retry queue's store abstraction, reused).
typealias BillingDataStore = PendingPurchaseStore

/// A JSON list on disk that knows exactly which contents were last written. A file that
/// exists but can't be read is never overwritten: writes fail until it reads again, then
/// what changed in memory meanwhile is merged over it. Not thread-safe; owned by `BillingEngine`.
final class DurableList<Element: Codable & Equatable> {
    private let store: BillingDataStore
    private let key: (Element) -> String
    private(set) var items: [Element] = []
    /// The contents of the last successful read or write, by key.
    private var saved: [String: Element] = [:]
    private(set) var isUnreadable = false
    private var removedWhileUnreadable = Set<String>()

    init(store: BillingDataStore, key: @escaping (Element) -> String) {
        self.store = store
        self.key = key
        _ = load()
    }

    /// Whether this exact element is on disk.
    func isSaved(_ element: Element) -> Bool {
        !isUnreadable && saved[key(element)] == element
    }

    /// Re-reads an unreadable file. True when the list reflects the file.
    @discardableResult
    func reloadIfUnreadable() -> Bool {
        isUnreadable ? load() : true
    }

    func upsert(_ element: Element) {
        let k = key(element)
        removedWhileUnreadable.remove(k)
        if let index = items.firstIndex(where: { key($0) == k }) {
            items[index] = element
        } else {
            items.append(element)
        }
    }

    func remove(key k: String) {
        items.removeAll { key($0) == k }
        if isUnreadable { removedWhileUnreadable.insert(k) }
    }

    /// Writes the list. True when everything in memory is on disk.
    @discardableResult
    func write() -> Bool {
        if isUnreadable, !load() { return false }
        guard let data = try? JSONEncoder().encode(items), (try? store.write(data)) != nil else { return false }
        saved = Dictionary(items.map { (key($0), $0) }, uniquingKeysWith: { _, last in last })
        return true
    }

    /// Reads the file and merges it under what is in memory (memory is newer).
    private func load() -> Bool {
        var onDisk: [Element] = []
        do {
            if let data = try store.read() {
                if let decoded = try? JSONDecoder().decode([Element].self, from: data) {
                    onDisk = decoded
                } else if !store.quarantine() {
                    isUnreadable = true
                    return false
                }
            }
        } catch {
            isUnreadable = true
            return false
        }
        isUnreadable = false
        saved = Dictionary(onDisk.map { (key($0), $0) }, uniquingKeysWith: { _, last in last })
        let inMemory = Set(items.map(key))
        items = onDisk.filter { !inMemory.contains(key($0)) && !removedWhileUnreadable.contains(key($0)) } + items
        removedWhileUnreadable.removeAll()
        return true
    }
}

/// Disk-backed list of rejected purchases. A transaction may be finished only once its
/// entry, with these exact contents, is on disk.
final class RejectedPurchaseLog {
    private let list: DurableList<AppReferRejectedPurchase>

    convenience init(fileURL: URL) {
        self.init(store: FilePendingPurchaseStore(fileURL: fileURL))
    }

    init(store: BillingDataStore) {
        list = DurableList(store: store, key: \.transactionId)
    }

    var entries: [AppReferRejectedPurchase] {
        list.reloadIfUnreadable()
        return list.items
    }

    func contains(transactionId: String) -> Bool {
        entries.contains { $0.transactionId == transactionId }
    }

    /// Adds or replaces the entry. True only when this entry is on disk.
    @discardableResult
    func add(_ entry: AppReferRejectedPurchase) -> Bool {
        list.reloadIfUnreadable()
        list.upsert(entry)
        return list.write() && list.isSaved(entry)
    }

    /// Drops the entry once AppRefer has recorded the purchase.
    func remove(transactionId: String) {
        list.reloadIfUnreadable()
        guard list.isUnreadable || list.items.contains(where: { $0.transactionId == transactionId }) else { return }
        list.remove(key: transactionId)
        list.write()
    }
}

/// Who opened a purchase sheet, saved before it opened, so a purchase delivered later
/// (Ask to Buy, slow payment, after a restart, logout or user switch) goes to them.
struct PurchaseIntent: Codable, Equatable, Sendable {
    var id = UUID()
    let appUserId: String
    let productId: String
    let accountToken: UUID?
    let startedAt: Date
}

/// Disk-backed purchase intents. Intents are removed when their purchase is recorded,
/// queued, rejected or cancelled; never by age, since Ask to Buy can stay pending.
final class PurchaseIntentStore {
    /// StoreKit's purchase date can be a little before our clock's start time.
    static let clockSlack: TimeInterval = 300

    enum Match: Equatable {
        case found(PurchaseIntent)
        case none
        /// The stored intents can't be read: the owner can't be known yet.
        case unreadable
    }

    private let list: DurableList<PurchaseIntent>

    convenience init(fileURL: URL) {
        self.init(store: FilePendingPurchaseStore(fileURL: fileURL))
    }

    init(store: BillingDataStore) {
        list = DurableList(store: store, key: { $0.id.uuidString })
    }

    /// Nil when the stored intents can't be read.
    var intents: [PurchaseIntent]? {
        list.reloadIfUnreadable() ? list.items : nil
    }

    /// True only when the intent is on disk.
    func add(_ intent: PurchaseIntent) -> Bool {
        guard list.reloadIfUnreadable() else { return false }
        list.upsert(intent)
        if list.write(), list.isSaved(intent) { return true }
        list.remove(key: intent.id.uuidString)
        return false
    }

    func remove(_ intent: PurchaseIntent) {
        list.reloadIfUnreadable()
        list.remove(key: intent.id.uuidString)
        list.write()
    }

    /// The intent a delivered original purchase belongs to: the one carrying its account
    /// token, or for an untagged purchase the oldest for the same product started before
    /// it (untagged intents first). Renewals never match: they belong to the original
    /// purchase's owner.
    func match(_ transaction: StoreTransaction) -> Match {
        guard transaction.originalId == transaction.id else { return .none }
        guard let intents else { return .unreadable }
        if let token = transaction.appAccountToken {
            return intents.first { $0.accountToken == token }.map(Match.found) ?? .none
        }
        let candidates = intents
            .filter { $0.productId == transaction.productId && $0.startedAt <= transaction.purchaseDate.addingTimeInterval(Self.clockSlack) }
            .sorted { ($0.accountToken == nil ? 0 : 1, $0.startedAt) < ($1.accountToken == nil ? 0 : 1, $1.startedAt) }
        return candidates.first.map(Match.found) ?? .none
    }
}
