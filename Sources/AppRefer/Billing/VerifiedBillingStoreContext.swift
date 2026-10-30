import Foundation
import StoreKit

/// A verified app transaction chooses routing scope only; it never grants an entitlement.
/// No receipt refresh, sign-in request, debug flag or TestFlight heuristic is used.
enum VerifiedBillingStoreContext {
    static func environment(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        lookup: @escaping @Sendable () async -> String? = verifiedEnvironment
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let reply = ContextReply(continuation)
            let lookupTask = Task { reply.finish(await lookup()) }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                reply.finish(nil)
                lookupTask.cancel()
            }
        }
    }

    private static func verifiedEnvironment() async -> String? {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            do {
                let result = try await AppTransaction.shared
                guard case .verified(let transaction) = result else { return nil }
                switch transaction.environment {
                case .production: return "production"
                case .sandbox, .xcode: return "sandbox"
                default: return nil
                }
            } catch { return nil }
        }
        return nil
    }

    private final class ContextReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        func finish(_ value: String?) {
            lock.lock()
            let target = continuation
            continuation = nil
            lock.unlock()
            target?.resume(returning: value == "production" || value == "sandbox" ? value : nil)
        }
    }
}
