import Foundation

public enum AppReferEventResult: Sendable { case sent, queued, dropped }
public enum AppReferAttributionError: Error { case unavailable }
public enum AppReferAttributionResult {
    case attributed(Attribution)
    case organic
    case failed(Error)
}

struct PendingProductEvent: Codable {
    let id: String
    let body: Data
    let created: Date
    var attempts: Int
    var nextAttempt: Date
}
