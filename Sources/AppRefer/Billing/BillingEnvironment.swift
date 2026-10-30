import Foundation

/// The store environment selected for a billing snapshot. Customer identity stays app-wide.
public enum BillingEnvironment: String, Codable, Sendable {
    case production
    case sandbox

    /// Read only from a StoreKit-verified local transaction, never to validate a queued receipt.
    static func localTransaction(_ jws: String) -> BillingEnvironment? {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch json["environment"] as? String {
        case "Production": return .production
        case "Sandbox", "Xcode", "LocalTesting": return .sandbox
        default: return nil
        }
    }

    static func select(apiKey: String, explicit: BillingEnvironment? = nil) throws -> BillingEnvironment {
        let test = apiKey.hasPrefix("pk_test_")
        if test && explicit == .production { throw AppReferBillingError.invalidResponse }
        return explicit ?? (test ? .sandbox : .production)
    }
}
