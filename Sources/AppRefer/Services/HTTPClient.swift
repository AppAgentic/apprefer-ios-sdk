import Foundation

final class AppReferHTTPClient: @unchecked Sendable {
    private let primaryURL: String
    private let fallbackURL: String?
    private let apiKey: String
    private let logger: AppReferLogger
    private let session: URLSession
    private let cancellationLock = NSLock()
    private var cancellationGeneration = 0
    private func generation() -> Int {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        return cancellationGeneration
    }
    private func advanceGeneration() {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        cancellationGeneration += 1
    }
    private let sdkVersion = AppReferVersion.current
    private let maxRetries = 3
    private let requestTimeout: TimeInterval = 10

    init(primaryURL: String, fallbackURL: String? = nil, apiKey: String, logger: AppReferLogger) {
        self.primaryURL = primaryURL
        self.fallbackURL = fallbackURL
        self.apiKey = apiKey
        self.logger = logger

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    /// Convenience init for backwards compatibility in tests.
    convenience init(backendURL: String, apiKey: String, logger: AppReferLogger) {
        self.init(primaryURL: backendURL, fallbackURL: nil, apiKey: apiKey, logger: logger)
    }

    func cancel() async {
        advanceGeneration()
        let tasks = await session.allTasks
        tasks.forEach { $0.cancel() }
    }

    /// One event attempt. Queue owns persistence and backoff, including 5xx.
    func event(_ body: [String: Any]) async -> Int? {
        guard let url = URL(string: primaryURL + "/api/track/event"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return 400 }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-AppRefer-Key")
        request.setValue(sdkVersion, forHTTPHeaderField: "X-SDK-Version")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch { return nil }
    }

    func post(_ path: String, body: [String: Any]) async -> [String: Any]? {
        let epoch = generation()
        // Try primary URL first
        if let result = await performPost(baseURL: primaryURL, path: path, body: body) {
            return result
        }

        guard epoch == generation() else { return nil }
        // Fallback if primary failed and a fallback URL is configured
        if let fallbackURL = fallbackURL, fallbackURL != primaryURL {
            logger.info("Primary URL failed, retrying on fallback: \(fallbackURL)\(path)")
            if let result = await performPost(baseURL: fallbackURL, path: path, body: body) {
                return result
            }
        }

        logger.error("POST \(path) failed on all endpoints")
        return nil
    }

    private func performPost(baseURL: String, path: String, body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            logger.error("Invalid URL: \(baseURL)\(path)")
            return nil
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            logger.error("Failed to serialize request body")
            return nil
        }

        let epoch = generation()
        for attempt in 0..<maxRetries {
            guard !Task.isCancelled else { return nil }
            if attempt > 0 {
                let delay = pow(2.0, Double(attempt))
                logger.debugLog("POST \(path) retry \(attempt) after \(Int(delay))s")
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return nil }
            }

            guard epoch == generation() else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(sdkVersion, forHTTPHeaderField: "X-SDK-Version")
            request.setValue(apiKey, forHTTPHeaderField: "X-AppRefer-Key")
            request.timeoutInterval = requestTimeout

            logger.debugLog("POST \(url)")

            do {
                let (data, response) = try await performRequest(request)
                guard epoch == generation() else { return nil }

                guard let httpResponse = response as? HTTPURLResponse else {
                    logger.error("POST \(path): invalid response")
                    return nil
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    if data.isEmpty { return [:] }
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return json
                    }
                    logger.error("POST \(path): failed to parse response")
                    return nil
                }

                // Don't retry 4xx (client errors)
                if (400..<500).contains(httpResponse.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    logger.error("POST \(path) failed: \(httpResponse.statusCode) \(body)")
                    return nil
                }

                // 5xx: retry
                logger.error("POST \(path) server error: \(httpResponse.statusCode) (attempt \(attempt + 1)/\(maxRetries))")
            } catch let error as URLError where error.code == .cancelled {
                return nil
            } catch is URLError {
                logger.error("POST \(path) network error (attempt \(attempt + 1)/\(maxRetries))")
            } catch {
                logger.error("POST \(path) exception: \(error)")
                return nil
            }
        }

        logger.error("POST \(path) failed after \(maxRetries) attempts on \(baseURL)")
        return nil
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
