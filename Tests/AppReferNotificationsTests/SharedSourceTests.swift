import XCTest
import CryptoKit

/// `EngagementPayload.swift` is shared by copy with the Flutter plugin and the React Native
/// module (their copies drop `public`). This copy must match the hash in shared-sources.json;
/// the parent's scripts/check-sdk-shared-sources.mjs keeps every copy and manifest equal.
final class SharedSourceTests: XCTestCase {
    func testSharedPayloadParserMatchesTheManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AppReferNotifications/EngagementPayload.swift"), encoding: .utf8)
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .filter { !$0.contains("(copied; keep in sync)") }
            .map { $0.replacingOccurrences(of: #"^(\s*)public "#, with: "$1", options: .regularExpression) }
            .joined(separator: "\n")
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared-sources.json"))) as? [String: String]
        XCTAssertEqual(hash, manifest?["engagementPayloadSwift"],
                       "EngagementPayload.swift changed without the shared copies: run node scripts/check-sdk-shared-sources.mjs in the parent repo")
    }

    /// `TestimonialMedia.swift` (0.13.0) is shared by copy with the Flutter and React Native iOS bridges.
    func testSharedTestimonialMediaMatchesTheManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AppRefer/Support/TestimonialMedia.swift"), encoding: .utf8)
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .filter { !$0.contains("(copied; keep in sync)") }
            .map { $0.replacingOccurrences(of: #"^(\s*)public "#, with: "$1", options: .regularExpression) }
            .joined(separator: "\n")
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared-sources.json"))) as? [String: String]
        XCTAssertEqual(hash, manifest?["testimonialMediaSwift"],
                       "TestimonialMedia.swift changed without the shared copies: run node scripts/check-sdk-shared-sources.mjs in the parent repo")
    }
    func testSharedBillingSourcesMatchManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared-sources.json"))) as? [String: String]
        for (name, file) in [("protectedBillingState", "ProtectedBillingState.swift"), ("verifiedBillingStoreContext", "VerifiedBillingStoreContext.swift")] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/AppRefer/Billing/" + file), encoding: .utf8)
            let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                .filter { !$0.contains("(copied; keep in sync)") }
                .map { $0.replacingOccurrences(of: #"^(\s*)public "#, with: "$1", options: .regularExpression) }.joined(separator: "\n")
            let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, manifest?[name])
        }
    }

}
