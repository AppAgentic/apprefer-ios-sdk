// Photo/video capture for Support testimonials: the system photo picker (no photo-library
// permission needed), the camera (only when the app declares NSCameraUsageDescription, and for
// video also NSMicrophoneUsageDescription), normalisation and a progress upload. Shared by copy
// with the Flutter and React Native iOS bridges: keep it free of the rest of the SDK.
//
// Photos are re-encoded as JPEG (at most 2048 px on the long side, no EXIF/GPS metadata).
// Videos are exported as MP4 with the moov atom first (fast start) and without location or other
// metadata (AVMetadataItemFilter.forSharing), and refused when longer than the request allows.
// The server checks the uploaded bytes again; the client's duration is never trusted there.
import Foundation
#if os(iOS)
import AVFoundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// A photo or video ready to upload: a temporary file the caller deletes when done.
struct TestimonialFile: Equatable, Sendable {
    let url: URL
    let contentType: String
    let size: Int
    let kind: String
    let durationMs: Int?
}

enum TestimonialMediaError: Error, Equatable {
    case tooLong(seconds: Int)
    case tooLarge
    case unreadable
    case cancelled
}

enum TestimonialMedia {
    static let maxImageBytes = 15 * 1024 * 1024
    static let maxVideoBytes = 150 * 1024 * 1024
    static let maxImageDimension: CGFloat = 2048

    /// The camera can be offered: a camera exists and the app declares the usage text(s) the
    /// system requires (without them, opening the camera would end the app).
    static func cameraAvailable(video: Bool, info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        guard info?["NSCameraUsageDescription"] != nil, !video || info?["NSMicrophoneUsageDescription"] != nil else { return false }
        // AVFoundation rather than UIImagePickerController.isSourceTypeAvailable: callable off the main actor.
        return AVCaptureDevice.default(for: .video) != nil
    }

    private static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("apprefer-testimonial-\(UUID().uuidString).\(ext)")
    }

    /// Scales to at most `maxImageDimension` on the long side and writes a JPEG without metadata.
    static func normalizeImage(_ image: UIImage, maxBytes: Int = maxImageBytes) throws -> TestimonialFile {
        let size = image.size
        guard size.width > 0, size.height > 0 else { throw TestimonialMediaError.unreadable }
        let scale = min(1, maxImageDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        var quality: CGFloat = 0.85
        var data = drawn.jpegData(compressionQuality: quality)
        while let d = data, d.count > maxBytes, quality > 0.4 {
            quality -= 0.15
            data = drawn.jpegData(compressionQuality: quality)
        }
        guard let data else { throw TestimonialMediaError.unreadable }
        guard data.count <= maxBytes else { throw TestimonialMediaError.tooLarge }
        let url = tempURL("jpg")
        try data.write(to: url, options: .atomic)
        return TestimonialFile(url: url, contentType: "image/jpeg", size: data.count, kind: "image", durationMs: nil)
    }

    /// Exports a video as fast-start MP4 without metadata, after checking its length.
    static func normalizeVideo(_ source: URL, maxSeconds: Int, maxBytes: Int = maxVideoBytes) async throws -> TestimonialFile {
        let asset = AVURLAsset(url: source)
        let duration: CMTime
        if #available(iOS 16, *) { duration = try await asset.load(.duration) } else { duration = asset.duration }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw TestimonialMediaError.unreadable }
        guard seconds <= Double(maxSeconds) + 0.5 else { throw TestimonialMediaError.tooLong(seconds: maxSeconds) }
        let out = tempURL("mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw TestimonialMediaError.unreadable }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.metadataItemFilter = .forSharing()
        export.metadata = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in export.exportAsynchronously { done.resume() } }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: out); throw TestimonialMediaError.unreadable }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        guard bytes > 0 else { throw TestimonialMediaError.unreadable }
        guard bytes <= maxBytes else { try? FileManager.default.removeItem(at: out); throw TestimonialMediaError.tooLarge }
        return TestimonialFile(url: out, contentType: "video/mp4", size: bytes, kind: "video", durationMs: Int((seconds * 1000).rounded()))
    }
}

/// Presents the system photo picker or the camera and hands back one normalised file.
final class TestimonialPicker: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    typealias Completion = @MainActor (Result<TestimonialFile, TestimonialMediaError>) -> Void
    private var completion: Completion?
    private var maxSeconds = 30
    /// Kept alive while a picker is on screen.
    @MainActor private static var current: TestimonialPicker?

    @MainActor
    static func library(from host: UIViewController, images: Bool, videos: Bool, maxSeconds: Int, completion: @escaping Completion) {
        let picker = TestimonialPicker()
        picker.completion = completion
        picker.maxSeconds = maxSeconds
        current = picker
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = images && videos ? .any(of: [.images, .videos]) : videos ? .videos : .images
        config.preferredAssetRepresentationMode = .compatible
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = picker
        host.present(vc, animated: true)
    }

    @MainActor
    static func camera(from host: UIViewController, images: Bool, videos: Bool, maxSeconds: Int, completion: @escaping Completion) {
        let picker = TestimonialPicker()
        picker.completion = completion
        picker.maxSeconds = maxSeconds
        current = picker
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.mediaTypes = (images ? [UTType.image.identifier] : []) + (videos ? [UTType.movie.identifier] : [])
        if videos {
            vc.videoMaximumDuration = TimeInterval(maxSeconds)
            vc.videoQuality = .typeHigh
        }
        vc.delegate = picker
        host.present(vc, animated: true)
    }

    @MainActor
    private func finish(_ result: Result<TestimonialFile, TestimonialMediaError>) {
        completion?(result)
        completion = nil
        Self.current = nil
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let provider = results.first?.itemProvider
        let maxSeconds = maxSeconds
        Task { @MainActor in
            guard let provider else { return finish(.failure(.cancelled)) }
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                let copy = await Self.copyMovie(provider)
                guard let copy else { return finish(.failure(.unreadable)) }
                defer { try? FileManager.default.removeItem(at: copy) }
                do { finish(.success(try await TestimonialMedia.normalizeVideo(copy, maxSeconds: maxSeconds))) } catch let e as TestimonialMediaError { finish(.failure(e)) } catch { finish(.failure(.unreadable)) }
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                let image = await Self.loadImage(provider)
                guard let image else { return finish(.failure(.unreadable)) }
                do { finish(.success(try TestimonialMedia.normalizeImage(image))) } catch let e as TestimonialMediaError { finish(.failure(e)) } catch { finish(.failure(.unreadable)) }
            } else {
                finish(.failure(.unreadable))
            }
        }
    }

    /// The picker's file is deleted when its callback returns: copy it out first.
    private static func copyMovie(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url else { return done.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("apprefer-pick-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
                do { try FileManager.default.copyItem(at: url, to: copy); done.resume(returning: copy) } catch { done.resume(returning: nil) }
            }
        }
    }

    private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { done in
            provider.loadObject(ofClass: UIImage.self) { object, _ in done.resume(returning: object as? UIImage) }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        Task { @MainActor in finish(.failure(.cancelled)) }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let movie = info[.mediaURL] as? URL
        let image = info[.originalImage] as? UIImage
        let maxSeconds = maxSeconds
        picker.dismiss(animated: true)
        Task { @MainActor in
            do {
                if let movie { finish(.success(try await TestimonialMedia.normalizeVideo(movie, maxSeconds: maxSeconds))) }
                else if let image { finish(.success(try TestimonialMedia.normalizeImage(image))) }
                else { finish(.failure(.unreadable)) }
            } catch let e as TestimonialMediaError { finish(.failure(e)) } catch { finish(.failure(.unreadable)) }
        }
    }
}

/// PUTs a file to its presigned URL, reporting progress (0...1). The signed headers must be sent unchanged.
final class TestimonialUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func put(_ file: URL, to url: URL, headers: [String: String], size: Int) async throws -> Int {
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "PUT"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.upload(for: req, fromFile: file)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
#endif
