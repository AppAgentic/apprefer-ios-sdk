import Foundation

final class AppReferHTTPClient: @unchecked Sendable {
    private let backendURL: String
    private let appId: String
    private let logger: AppReferLogger
    private let session: URLSession
    private let sdkVersion = "0.1.0"
    private let maxRetries = 3
    private let requestTimeout: TimeInterval = 10

    init(backendURL: String, appId: String, logger: AppReferLogger) {
        self.backendURL = backendURL
        self.appId = appId
        self.logger = logger

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    func post(_ path: String, body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: "\(backendURL)\(path)") else {
            logger.error("Invalid URL: \(backendURL)\(path)")
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
            request.setValue(appId, forHTTPHeaderField: "X-App-Id")
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

        logger.error("POST \(path) failed after \(maxRetries) attempts")
        return nil
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if #available(iOS 15.0, macOS 12.0, *) {
            return try await session.data(for: request)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
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
