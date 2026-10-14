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
    /// Set when the owner was a guess support should check (the purchase intents were
    /// lost, so it went to whoever was signed in after the 48 hour wait).
    public var supportNote: String? = nil
}

/// Where a durable list is kept (the retry queue's store abstraction, reused).
typealias BillingDataStore = PendingPurchaseStore

/// Decodes one list element, nil instead of failing the whole list.
private struct Salvaged<Element: Decodable>: Decodable {
    let value: Element?
    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

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
    /// Runs before an undecodable file is moved aside; false keeps it unreadable instead.
    private let beforeQuarantine: (() -> Bool)?
    /// When the file is partly malformed, keep the entries that decode (the raw original is
    /// still moved aside and the file rewritten with them). Otherwise nothing is kept.
    private let keepsParseableEntries: Bool

    init(
        store: BillingDataStore,
        key: @escaping (Element) -> String,
        beforeQuarantine: (() -> Bool)? = nil,
        keepsParseableEntries: Bool = false
    ) {
        self.store = store
        self.key = key
        self.beforeQuarantine = beforeQuarantine
        self.keepsParseableEntries = keepsParseableEntries
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
        var salvaged = false
        do {
            if let data = try store.read() {
                if let decoded = try? JSONDecoder().decode([Element].self, from: data) {
                    onDisk = decoded
                } else if beforeQuarantine?() == false || !store.quarantine() {
                    isUnreadable = true
                    return false
                } else {
                    // Moved aside. Keep what still decodes (none if not even the list does).
                    salvaged = true
                    if keepsParseableEntries {
                        onDisk = ((try? JSONDecoder().decode([Salvaged<Element>].self, from: data)) ?? []).compactMap(\.value)
                    }
                }
            }
        } catch {
            isUnreadable = true
            return false
        }
        isUnreadable = false
        // After a quarantine nothing is on disk until the kept entries are written back.
        saved = salvaged ? [:] : Dictionary(onDisk.map { (key($0), $0) }, uniquingKeysWith: { _, last in last })
        let inMemory = Set(items.map(key))
        items = onDisk.filter { !inMemory.contains(key($0)) && !removedWhileUnreadable.contains(key($0)) } + items
        removedWhileUnreadable.removeAll()
        if salvaged, !items.isEmpty { write() }
        return true
    }
}

/// Disk-backed list of rejected purchases. A transaction may be finished only once its
/// entry, with these exact contents, is on disk. No size cap: entries leave only when
/// AppRefer records the purchase.
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

/// Saved when an undecodable intents file is moved aside: who started the purchases in it
/// is unknown, so untagged deliveries wait (see `PurchaseIntentStore.Match.lost`).
final class IntentsLostMarker {
    enum State: Equatable {
        case absent
        case lost(since: Date)
        case unreadable
    }

    private let store: BillingDataStore
    private struct Contents: Codable { let lostAt: Date }

    init(store: BillingDataStore) {
        self.store = store
    }

    var state: State {
        let data: Data?
        do { data = try store.read() } catch { return .unreadable }
        guard let data else { return .absent }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return .unreadable }
        return .lost(since: contents.lostAt)
    }

    /// Records the loss, keeping an earlier date. True when the marker is on disk.
    func markLost(at date: Date) -> Bool {
        if case .lost = state { return true }
        guard let data = try? JSONEncoder().encode(Contents(lostAt: date)) else { return false }
        return (try? store.write(data)) != nil && state == .lost(since: date)
    }

    func clear() {
        try? store.remove()
    }
}

/// Disk-backed purchase intents. Intents are removed only on a definitive outcome: the
/// purchase recorded, durably queued or archived, or the sheet cancelled or failed for
/// good. Never by age, since Ask to Buy can stay pending. An undecodable file is moved
/// aside only after an `IntentsLostMarker` is saved; the intents in it that still decode
/// are kept and written back.
final class PurchaseIntentStore {
    /// How long an untagged purchase waits for its owner while intents are lost: inside
    /// Google's 3-day acknowledgement window, so every SDK behaves the same.
    static let lostIntentsWait: TimeInterval = 48 * 3600

    enum Match: Equatable {
        case found(PurchaseIntent)
        case none
        /// The stored intents can't be read: the owner can't be known yet.
        case unreadable
        /// The intents file was undecodable and moved aside on this date.
        case lost(since: Date)
    }

    private let list: DurableList<PurchaseIntent>
    let lostMarker: IntentsLostMarker

    convenience init(fileURL: URL, now: @escaping () -> Date = { Date() }) {
        self.init(
            store: FilePendingPurchaseStore(fileURL: fileURL),
            lostMarker: FilePendingPurchaseStore(fileURL: fileURL.deletingPathExtension().appendingPathExtension("lost.json")),
            now: now
        )
    }

    init(store: BillingDataStore, lostMarker markerStore: BillingDataStore, now: @escaping () -> Date = { Date() }) {
        let marker = IntentsLostMarker(store: markerStore)
        lostMarker = marker
        list = DurableList(
            store: store, key: { $0.id.uuidString },
            beforeQuarantine: { marker.markLost(at: now()) }, keepsParseableEntries: true
        )
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

    /// The intent a delivered new purchase belongs to: the one carrying its account token,
    /// or for an untagged purchase the oldest for the same product, tagged or not.
    /// Renewals (`originalId != id`) never match: they belong to the original purchase's
    /// owner. While intents are lost, an untagged purchase with no surviving intent for its
    /// product gets `.lost`; one that does still goes to that intent's owner.
    func match(_ transaction: StoreTransaction) -> Match {
        guard !transaction.isRenewal else { return .none }
        guard let intents else { return .unreadable }
        if let token = transaction.appAccountToken {
            return intents.first { $0.accountToken == token }.map(Match.found) ?? .none
        }
        // Oldest by `startedAt` explicitly, never by stored order; `min` keeps the first of a tie.
        // Intents that survived a partial corruption still decide ownership.
        if let surviving = intents
            .filter({ $0.productId == transaction.productId })
            .min(by: { $0.startedAt < $1.startedAt }) {
            return .found(surviving)
        }
        switch lostMarker.state {
        case .lost(let since): return .lost(since: since)
        case .unreadable: return .unreadable
        case .absent: return .none
        }
    }
}
