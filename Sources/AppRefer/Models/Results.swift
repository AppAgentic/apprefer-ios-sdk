import Foundation

public enum AppReferEventResult: Sendable { case sent, queued, dropped }
public enum AppReferAttributionError: Error { case unavailable }
public enum AppReferAttributionResult {
    case attributed(Attribution)
    case pending
    case organic
    case failed(Error)
}

struct PendingProductEvent: Codable {
    let id: String
    let body: Data
    let created: Date
    var attempts: Int
    var nextAttempt: Date
    /// Engagement identity stamp at enqueue (never the credential); absent in older queues.
    var engagementStamp: String? = nil
}
