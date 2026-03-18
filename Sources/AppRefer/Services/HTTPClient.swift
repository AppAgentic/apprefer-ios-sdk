import Foundation

final class AppReferHTTPClient: @unchecked Sendable {
    private let primaryURL: String
    private let fallbackURL: String?
    private let apiKey: String
    private let logger: AppReferLogger
    private let session: URLSession
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

    func post(_ path: String, body: [String: Any]) async -> [String: Any]? {
        // Try primary URL first
        if let result = await performPost(baseURL: primaryURL, path: path, body: body) {
            return result
        }

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

        for attempt in 0..<maxRetries {
            if attempt > 0 {
                let delay = pow(2.0, Double(attempt))
                logger.debugLog("POST \(path) retry \(attempt) after \(Int(delay))s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

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
        if #available(iOS 15.0, macOS 12.0, *) {
            return try await session.data(for: request)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                var resumed = false
                let task = session.dataTask(with: request) { data, response, error in
                    guard !resumed else { return }
                    resumed = true
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data, let response = response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                task.resume()
            }
        }
    }
}
