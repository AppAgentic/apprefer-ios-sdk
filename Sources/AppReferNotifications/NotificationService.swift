#if os(iOS) || os(macOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

/// Settings for `AppReferNotificationService`, chosen by the host app in its extension.
public struct AppReferNotificationServiceConfiguration: Sendable {
    /// Exact host names images may come from (e.g. `["assets.example.com"]`). Empty: never
    /// fetch. Use public, versioned, generic artwork; never per-user content.
    public var allowedImageHosts: Set<String>
    /// Largest image accepted, in bytes (default 300 KB, at most 5 MB).
    public var maxImageBytes: Int
    /// Time allowed for the download (default 8 s, at most 25 s: the system gives an
    /// extension about 30 s and the text must still go out in time).
    public var timeout: TimeInterval
    /// Largest accepted width or height in pixels (default 2048, at most 4096).
    public var maxPixelDimension: Int
    /// App Group shared with the app (`AppRefer.engagement` options use the same one). With
    /// it the extension skips images for another install or account and records "received".
    public var appGroup: String?

    public init(allowedImageHosts: Set<String>, maxImageBytes: Int = 300_000, timeout: TimeInterval = 8,
                maxPixelDimension: Int = 2048, appGroup: String? = nil) {
        self.allowedImageHosts = Set(allowedImageHosts.filter(AppReferImagePolicy.isHost))
        self.maxImageBytes = min(max(maxImageBytes, 1024), 5 * 1024 * 1024)
        self.timeout = min(max(timeout, 1), 25)
        self.maxPixelDimension = min(max(maxPixelDimension, 64), 4096)
        self.appGroup = appGroup
    }
}

/// Notification Service Extension helper for AppRefer lifecycle notifications: adds the
/// message's image when it can be fetched safely and in time, and otherwise delivers the
/// complete text notification unchanged. Extension-safe: Foundation, ImageIO and
/// UserNotifications only, no `UIApplication`, no dependency on the main AppRefer module.
///
/// ```swift
/// final class NotificationService: UNNotificationServiceExtension {
///     private let appRefer = AppReferNotificationService(configuration: .init(
///         allowedImageHosts: ["assets.example.com"], appGroup: "group.com.example.app"))
///
///     override func didReceive(_ request: UNNotificationRequest,
///                              withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
///         if appRefer.didReceive(request, withContentHandler: contentHandler) { return }
///         contentHandler(request.content) // not AppRefer's: your own handling
///     }
///
///     override func serviceExtensionTimeWillExpire() {
///         appRefer.serviceExtensionTimeWillExpire()
///     }
/// }
/// ```
///
/// Guarantees: the content handler runs exactly once per claimed request, including when
/// the download, the extension's own deadline and `serviceExtensionTimeWillExpire` race;
/// redirects are refused; only `image/png` and `image/jpeg` responses whose bytes decode as
/// that type, within the byte and pixel limits, are attached; downloads use an ephemeral
/// session (no cookies or URL cache); files get unique names and leftovers are removed.
public final class AppReferNotificationService: @unchecked Sendable {
    public let configuration: AppReferNotificationServiceConfiguration
    private let sessionConfiguration: URLSessionConfiguration
    private let directory: URL
    private let lock = NSLock()
    private var deliveries: [UUID: Delivery] = [:]

    public convenience init(configuration: AppReferNotificationServiceConfiguration) {
        self.init(configuration: configuration, sessionConfiguration: .ephemeral, directory: nil)
    }

    init(configuration: AppReferNotificationServiceConfiguration, sessionConfiguration: URLSessionConfiguration, directory: URL?) {
        self.configuration = configuration
        let session = sessionConfiguration
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.httpShouldSetCookies = false
        session.urlCredentialStorage = nil
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        session.waitsForConnectivity = false
        session.timeoutIntervalForRequest = configuration.timeout
        session.timeoutIntervalForResource = configuration.timeout
        session.httpAdditionalHeaders = ["Accept": "image/png, image/jpeg"]
        self.sessionConfiguration = session
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("AppReferNotifications", isDirectory: true)
    }

    /// Handles the request when it is an AppRefer engagement notification and returns true;
    /// `contentHandler` is then called exactly once. Returns false (and never calls it) for
    /// any other notification, including Support replies.
    @discardableResult
    public func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) -> Bool {
        let parsed = AppReferEngagementPayload.parse(userInfo: request.content.userInfo)
        guard parsed != .notEngagement else { return false }
        let text = request.content
        guard case .valid(let payload) = parsed else { contentHandler(text); return true }

        let shared = configuration.appGroup.map(AppReferNotificationSharedState.init(appGroup:))
        // Another install or account: never fetch for it (its text is generic by design).
        let sameIdentity = shared?.matches(payload) ?? true
        if let shared, sameIdentity {
            shared.appendReceived(.init(messageId: payload.messageId, installId: payload.installId, accountEpoch: payload.accountEpoch,
                                        receiptToken: payload.receiptToken, receivedAt: Date()))
        }
        guard sameIdentity, !payload.isExpired(), let url = payload.imageURL,
              AppReferImagePolicy.isAllowed(url, allowedHosts: configuration.allowedImageHosts) else {
            contentHandler(text)
            return true
        }

        let id = UUID()
        let delivery = Delivery(text: text, handler: contentHandler) { [weak self] in self?.remove(id) }
        lock.lock(); deliveries[id] = delivery; lock.unlock()
        removeLeftovers()
        let download = ImageDownload(url: url, configuration: configuration, sessionConfiguration: sessionConfiguration) { [weak self] result in
            guard let self else { delivery.finish(nil); return }
            delivery.finish(result.flatMap { self.attach($0, to: text) })
        }
        delivery.download = download
        // Our own deadline, well before the system's: the text always goes out in time.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + configuration.timeout + 0.5) { [weak delivery] in
            delivery?.finish(nil)
        }
        download.start()
        return true
    }

    /// Call from `serviceExtensionTimeWillExpire()`: every pending notification goes out as
    /// complete text now (an image that arrives later is discarded).
    public func serviceExtensionTimeWillExpire() {
        lock.lock(); let pending = Array(deliveries.values); lock.unlock()
        pending.forEach { $0.finish(nil) }
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return deliveries.count }

    private func remove(_ id: UUID) { lock.lock(); deliveries[id] = nil; lock.unlock() }

    private func attach(_ image: DownloadedImage, to text: UNNotificationContent) -> UNNotificationContent? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(UUID().uuidString).\(image.type == .png ? "png" : "jpg")")
            try image.data.write(to: file, options: [.atomic])
            do {
                // The system moves the file into its own store.
                let attachment = try UNNotificationAttachment(identifier: "apprefer-image", url: file,
                                                              options: [UNNotificationAttachmentOptionsTypeHintKey: image.type.identifier])
                guard let content = text.mutableCopy() as? UNMutableNotificationContent else { return nil }
                content.attachments = [attachment]
                return content
            } catch {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
        } catch {
            return nil
        }
    }

    /// Files left behind by a process that ended mid-download.
    private func removeLeftovers() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 600 { try? fm.removeItem(at: file) }
        }
    }
}

/// One claimed notification: delivers exactly once, whichever of download, deadline and
/// expiry comes first.
final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let text: UNNotificationContent
    private let handler: (UNNotificationContent) -> Void
    private let onFinish: () -> Void
    var download: ImageDownload?

    init(text: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void, onFinish: @escaping () -> Void) {
        self.text = text; self.handler = handler; self.onFinish = onFinish
    }

    /// nil = the text alone.
    func finish(_ content: UNNotificationContent?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let download = self.download
        self.download = nil
        lock.unlock()
        download?.cancel()
        handler(content ?? text)
        onFinish()
    }
}

struct DownloadedImage { let data: Data; let type: UTType }

/// A bounded image download that refuses redirects and checks status, MIME type, size,
/// decodability and pixel dimensions.
final class ImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let configuration: AppReferNotificationServiceConfiguration
    private let sessionConfiguration: URLSessionConfiguration
    private let completion: (DownloadedImage?) -> Void
    private let lock = NSLock()
    private var data = Data()
    private var type: UTType?
    private var completed = false
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(url: URL, configuration: AppReferNotificationServiceConfiguration, sessionConfiguration: URLSessionConfiguration, completion: @escaping (DownloadedImage?) -> Void) {
        self.url = url; self.configuration = configuration; self.sessionConfiguration = sessionConfiguration; self.completion = completion
    }

    func start() {
        let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeout))
        lock.lock(); self.session = session; self.task = task; lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock(); let task = self.task; lock.unlock()
        task?.cancel()
    }

    private func complete(_ image: DownloadedImage?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let session = self.session
        self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        completion(image)
    }

    // Never follow a redirect: it could lead off the allowlisted host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        task.cancel()
        complete(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == url.host,
              // The declared type, not one the loader sniffed from the bytes.
              let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              let type: UTType = mime == "image/png" ? .png : (mime == "image/jpeg" ? .jpeg : nil),
              http.expectedContentLength <= Int64(configuration.maxImageBytes) else {
            completionHandler(.cancel)
            complete(nil)
            return
        }
        lock.lock(); self.type = type; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        data.append(chunk)
        let tooLarge = data.count > configuration.maxImageBytes
        lock.unlock()
        if tooLarge { dataTask.cancel(); complete(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let bytes = data; let type = self.type; lock.unlock()
        guard error == nil, let type, !bytes.isEmpty, bytes.count <= configuration.maxImageBytes,
              Self.decodes(bytes, as: type, maxPixels: configuration.maxPixelDimension) else { complete(nil); return }
        complete(DownloadedImage(data: bytes, type: type))
    }

    /// The bytes are one image of the declared type, within the pixel limit.
    static func decodes(_ data: Data, as type: UTType, maxPixels: Int) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let actual = CGImageSourceGetType(source) as String?, actual == type.identifier,
              CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxPixels, height <= maxPixels else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
    }
}
#endif
