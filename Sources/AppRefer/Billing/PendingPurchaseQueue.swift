import Foundation

/// A verified StoreKit transaction AppRefer has not accepted yet.
struct PendingPurchase: Codable, Equatable, Sendable {
    let transactionId: String
    let productId: String
    let appUserId: String
    let appreferId: String?
    let signedTransaction: String
    let enqueuedAt: Date
    var attempts: Int
    /// Queued by Restore Purchases, so the retry is still sent as a restore.
    var restore: Bool? = nil
}

/// Where the retry queue is kept. Abstracted so write and read failures are testable.
protocol PendingPurchaseStore {
    /// The stored bytes; nil when nothing was ever saved. Throws when the file exists
    /// but can't be read right now.
    func read() throws -> Data?
    func write(_ data: Data) throws
    /// Moves undecodable contents aside so they are kept but no longer block the queue.
    func quarantine() -> Bool
}

struct FilePendingPurchaseStore: PendingPurchaseStore {
    let fileURL: URL

    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BillingStorage.writeChecked(data, to: fileURL)
    }

    func quarantine() -> Bool {
        let aside = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
        return (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil
    }
}

/// Disk-backed retry queue. A StoreKit transaction is finished only once its entry is
/// durably saved here (or AppRefer recorded it); the signed JWS stays here until AppRefer
/// accepts it. Entries whose last save failed are provisional: kept in memory and saved
/// again before the transaction is finished. A queue file that exists but can't be read
/// is never overwritten; it is read again before the next write. Not thread-safe; owned
/// by `BillingEngine`.
final class PendingPurchaseQueue {
    static let maxAttempts = 50
    static let maxAge: TimeInterval = 90 * 24 * 3600

    private let store: PendingPurchaseStore
    private(set) var entries: [PendingPurchase] = []
    /// Entries whose latest version is only in memory.
    private var provisionalIds = Set<String>()
    /// The file exists but couldn't be read: nothing is written until it can be.
    private(set) var isUnreadable = false

    convenience init(fileURL: URL) {
        self.init(store: FilePendingPurchaseStore(fileURL: fileURL))
    }

    init(store: PendingPurchaseStore) {
        self.store = store
        _ = load()
    }

    var isEmpty: Bool { entries.isEmpty }

    func contains(appUserId: String) -> Bool {
        entries.contains { $0.appUserId == appUserId }
    }

    func entry(transactionId: String) -> PendingPurchase? {
        entries.first { $0.transactionId == transactionId }
    }

    /// Whether the entry is saved on disk, so its StoreKit transaction may be finished.
    func isDurable(transactionId: String) -> Bool {
        !isUnreadable && entry(transactionId: transactionId) != nil && !provisionalIds.contains(transactionId)
    }

    var hasProvisionalEntries: Bool { isUnreadable || !provisionalIds.isEmpty }

    /// Adds or refreshes an entry; one entry per transaction id. An explicit restore takes
    /// the entry over (owner and restore intent together); an ordinary delivery never
    /// rewrites a queued restore. Returns whether the entry is now durably saved.
    @discardableResult
    func add(_ entry: PendingPurchase) -> Bool {
        if let index = entries.firstIndex(where: { $0.transactionId == entry.transactionId }) {
            if entries[index].restore == true, entry.restore != true {
                return isDurable(transactionId: entry.transactionId) || save(changed: entry.transactionId)
            }
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        return save(changed: entry.transactionId)
    }

    @discardableResult
    func remove(transactionId: String) -> Bool {
        entries.removeAll { $0.transactionId == transactionId }
        provisionalIds.remove(transactionId)
        return save(changed: nil)
    }

    func recordAttempt(transactionId: String) {
        guard let index = entries.firstIndex(where: { $0.transactionId == transactionId }) else { return }
        entries[index].attempts += 1
        save(changed: nil)
    }

    /// Saves provisional entries (and re-reads an unreadable file). True when everything
    /// in memory is on disk.
    @discardableResult
    func retryPersistence() -> Bool {
        guard hasProvisionalEntries else { return true }
        return save(changed: nil)
    }

    /// Drops entries that have failed too often or are too old. The server still gets
    /// those purchases from App Store Server Notifications. An entry that isn't saved yet
    /// is kept: its StoreKit transaction is still unfinished, and dropping it would leave
    /// the purchase with neither a retry copy nor a server record.
    @discardableResult
    func prune(now: Date = Date()) -> [PendingPurchase] {
        let dropped = entries.filter {
            isDurable(transactionId: $0.transactionId)
                && ($0.attempts >= Self.maxAttempts || now.timeIntervalSince($0.enqueuedAt) > Self.maxAge)
        }
        guard !dropped.isEmpty else { return [] }
        let ids = Set(dropped.map(\.transactionId))
        entries.removeAll { ids.contains($0.transactionId) }
        provisionalIds.subtract(ids)
        save(changed: nil)
        return dropped
    }

    /// Reads the file and merges it under what is in memory (memory wins: it is newer).
    private func load() -> Bool {
        var onDisk: [PendingPurchase] = []
        do {
            if let data = try store.read() {
                if let decoded = try? JSONDecoder().decode([PendingPurchase].self, from: data) {
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
        let inMemory = Set(entries.map(\.transactionId))
        provisionalIds.formUnion(inMemory)
        entries = onDisk.filter { !inMemory.contains($0.transactionId) } + entries
        return true
    }

    @discardableResult
    private func save(changed transactionId: String?) -> Bool {
        if let transactionId { provisionalIds.insert(transactionId) }
        if isUnreadable, !load() { return false }
        guard let data = try? JSONEncoder().encode(entries), (try? store.write(data)) != nil else { return false }
        provisionalIds.removeAll()
        return true
    }
}
