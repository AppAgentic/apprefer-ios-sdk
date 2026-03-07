import Foundation
import os

final class AppReferLogger: @unchecked Sendable {
    private let debug: Bool
    private let logLevel: Int
    private let log: OSLog

    init(debug: Bool, logLevel: Int) {
        self.debug = debug
        self.logLevel = logLevel
        self.log = OSLog(subsystem: "com.apprefer.sdk", category: "AppRefer")
    }

    func info(_ message: String) {
        guard logLevel >= 2 else { return }
        os_log("[AppRefer] %{public}@", log: log, type: .info, message)
    }

    func error(_ message: String) {
        guard logLevel >= 1 else { return }
        os_log("[AppRefer] %{public}@", log: log, type: .error, message)
    }

    func debugLog(_ message: String) {
        guard debug, logLevel >= 3 else { return }
        os_log("[AppRefer] %{public}@", log: log, type: .debug, message)
    }

    func warn(_ message: String) {
        guard logLevel >= 2 else { return }
        os_log("[AppRefer] %{public}@", log: log, type: .default, message)
    }
}
