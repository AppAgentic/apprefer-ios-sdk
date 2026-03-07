import CryptoKit
import Foundation

enum AppReferHashing {
    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hash an email: lowercase, trim, then SHA256.
    static func hashEmail(_ email: String) -> String {
        sha256(email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Hash a phone number: strip non-digits, then SHA256.
    static func hashPhone(_ phone: String) -> String {
        let digitsOnly = phone.filter(\.isNumber)
        return sha256(digitsOnly)
    }

    /// Hash a name: lowercase, trim, then SHA256.
    static func hashName(_ name: String) -> String {
        sha256(name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Hash a date of birth: trim, then SHA256.
    static func hashDateOfBirth(_ dob: String) -> String {
        sha256(dob.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
