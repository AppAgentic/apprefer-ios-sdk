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
}

/// Disk-backed retry queue. Transactions are finished with StoreKit as soon as they
/// are queued (so StoreKit never redelivers forever); the signed JWS stays here until
/// AppRefer accepts it. Not thread-safe; owned by `BillingEngine`.
final class PendingPurchaseQueue {
    static let maxAttempts = 50
    static let maxAge: TimeInterval = 90 * 24 * 3600

    private let fileURL: URL
    private(set) var entries: [PendingPurchase]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PendingPurchase].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    func contains(appUserId: String) -> Bool {
        entries.contains { $0.appUserId == appUserId }
    }

    /// Adds or refreshes an entry; one entry per transaction id.
    func add(_ entry: PendingPurchase) {
        if let index = entries.firstIndex(where: { $0.transactionId == entry.transactionId }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    func remove(transactionId: String) {
        entries.removeAll { $0.transactionId == transactionId }
        save()
    }

    func recordAttempt(transactionId: String) {
        guard let index = entries.firstIndex(where: { $0.transactionId == transactionId }) else { return }
        entries[index].attempts += 1
        save()
    }

    /// Drops entries that have failed too often or are too old. The server still gets
    /// those purchases from App Store Server Notifications.
    @discardableResult
    func prune(now: Date = Date()) -> [PendingPurchase] {
        let dropped = entries.filter {
            $0.attempts >= Self.maxAttempts || now.timeIntervalSince($0.enqueuedAt) > Self.maxAge
        }
        guard !dropped.isEmpty else { return [] }
        let ids = Set(dropped.map(\.transactionId))
        entries.removeAll { ids.contains($0.transactionId) }
        save()
        return dropped
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        BillingStorage.write(data, to: fileURL)
    }
}
