import Foundation

/// Atomic, install-local billing capabilities. The temporary file is protected and
/// excluded from backup before rename, including the first write.
enum ProtectedBillingState {
    static func wrapperURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AppRefer/Billing/wrapper-automatic-environments-v1.json")
    }
    static func read(from file: URL) throws -> Data? {
        do { return try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    static func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.completeFileProtection])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var protectedURL = temporary; try protectedURL.setResourceValues(values)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: file) }
    }
}
