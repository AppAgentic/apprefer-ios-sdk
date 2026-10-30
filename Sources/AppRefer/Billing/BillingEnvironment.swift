import Foundation

/// The store environment selected for a billing snapshot. Customer identity stays app-wide.
public enum BillingEnvironment: String, Codable, Sendable {
    case production
    case sandbox

    static func select(apiKey: String, explicit: BillingEnvironment? = nil) throws -> BillingEnvironment {
        let test = apiKey.hasPrefix("pk_test_")
        if test && explicit == .production { throw AppReferBillingError.invalidResponse }
        return explicit ?? (test ? .sandbox : .production)
    }
}
