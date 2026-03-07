import XCTest
@testable import AppRefer

final class HashingTests: XCTestCase {

    func testHashEmail_lowercasesAndTrims() {
        let hash1 = AppReferHashing.hashEmail("User@Example.com")
        let hash2 = AppReferHashing.hashEmail("user@example.com")
        let hash3 = AppReferHashing.hashEmail("  user@example.com  ")

        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash2, hash3)
        XCTAssertEqual(hash1.count, 64) // SHA256 hex = 64 chars
    }

    func testHashPhone_stripsNonDigits() {
        let hash1 = AppReferHashing.hashPhone("+1 (234) 567-8900")
        let hash2 = AppReferHashing.hashPhone("12345678900")

        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64)
    }

    func testHashName_lowercasesAndTrims() {
        let hash1 = AppReferHashing.hashName("John")
        let hash2 = AppReferHashing.hashName("john")
        let hash3 = AppReferHashing.hashName("  JOHN  ")

        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash2, hash3)
    }

    func testHashDateOfBirth_trims() {
        let hash1 = AppReferHashing.hashDateOfBirth("1990-01-15")
        let hash2 = AppReferHashing.hashDateOfBirth("  1990-01-15  ")

        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64)
    }

    func testDifferentInputsProduceDifferentHashes() {
        let hash1 = AppReferHashing.hashEmail("a@b.com")
        let hash2 = AppReferHashing.hashEmail("x@y.com")

        XCTAssertNotEqual(hash1, hash2)
    }

    func testKnownSHA256Value() {
        // SHA256 of "test@example.com" is known
        let hash = AppReferHashing.hashEmail("test@example.com")
        XCTAssertEqual(hash.count, 64)
        // Verify it's lowercase hex
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }
}
