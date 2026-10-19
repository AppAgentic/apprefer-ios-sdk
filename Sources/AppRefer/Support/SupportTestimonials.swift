import Foundation

// Photo/video testimonials (server: lib/support/testimonials.ts). A request is always made by
// something the app trusts (its backend, its coach tool, a person in Support, the AI within the
// app's policy, or automation); this SDK only answers one, for the account the support session is
// verified for (`AppRefer.support.verifyIdentity`). The reward and the publication permission
// text come from the request: the SDK never chooses a reward and never ties it to what is said.
// Taking part earns the reward; public use is a separate switch that starts on and the customer
// can turn off. Only the final button sends its value ("Send and allow sharing" / "Send
// privately"), with the permission version shown.

/// A photo/video request as the server sends it.
public struct AppReferTestimonialRequest: Hashable, Sendable, Decodable {
    public struct Reward: Hashable, Sendable, Decodable {
        /// credits, coach_usage, subscription_time, discount, gift, merch or manual.
        public let type: String
        /// What the customer gets, as the app wrote it (e.g. "50 bonus credits").
        public let description: String?
    }
    public struct Permission: Hashable, Sendable, Decodable {
        /// Exactly what a "yes" to public use allows, shown word for word.
        public let text: String
        public let scopes: [String]
        /// Sent back with the answer so the server knows which text was shown.
        public let version: String
    }

    public let requestId: String
    /// open, submitted, declined, expired, withdrawn or unavailable.
    public let status: String
    public let campaignId: String?
    public let title: String?
    public let prompt: String?
    /// "image" and/or "video".
    public let media: [String]?
    public let maxVideoSeconds: Int?
    public let maxImageBytes: Int?
    public let maxVideoBytes: Int?
    /// nil when the campaign has no reward.
    public let reward: Reward?
    public let permission: Permission?
    public let expiresAt: String?
    public let submittedAt: String?
    /// granted, declined, revoked, or nil before an answer.
    public let publication: String?
    /// none (nothing earned yet), pending, delivered, fulfilled, failed, timed_out or not_eligible.
    public let rewardStatus: String?

    public var isOpen: Bool { status == "open" }
    public var allowsImages: Bool { media?.contains("image") ?? false }
    public var allowsVideos: Bool { media?.contains("video") ?? false }

    /// The table key for the reward line after sharing. Confirmed only once the app's backend
    /// reported its receipt (`fulfilled`); in-account rewards say "added to your account", anything
    /// else just "confirmed" (no delivery or email promise).
    var rewardStatusKey: String {
        switch rewardStatus {
        case "fulfilled":
            return ["credits", "coach_usage", "subscription_time"].contains(reward?.type ?? "")
                ? "support.testimonial.rewardDone.account" : "support.testimonial.rewardDone"
        case "failed", "timed_out": return "support.testimonial.rewardDelayed"
        case "not_eligible": return "support.testimonial.rewardNotEligible"
        default: return "support.testimonial.rewardPending"
        }
    }
}

/// How a capture screen ended, and the reward's state then.
public struct AppReferTestimonialResult: Equatable, Sendable {
    public enum Outcome: String, Sendable { case submitted, declined, cancelled, unavailable }
    public let requestId: String
    public let outcome: Outcome
    /// See `AppReferTestimonialRequest.rewardStatus`.
    public let rewardStatus: String?
    public let publication: String?
}

/// A reward state change the SDK saw (after a share, or `rewardStatus(requestId:)`). When it is
/// `fulfilled` your backend has confirmed the reward: refresh the user's credits or usage.
public struct AppReferTestimonialRewardUpdate: Equatable, Sendable {
    public let requestId: String
    public let rewardStatus: String
}

struct SupportTestimonialEnvelope: Decodable { let request: AppReferTestimonialRequest }
struct SupportTestimonialList: Decodable { let requests: [AppReferTestimonialRequest] }
struct SupportTestimonialSlot: Decodable { let uploadId: String; let uploadUrl: String; let headers: [String: String] }

/// What the capture flow needs from the network (a protocol so tests can stand in for it).
protocol TestimonialTransport: Sendable {
    func request(_ id: String, generation: Int) async throws -> AppReferTestimonialRequest
    func slot(_ id: String, contentType: String, size: Int, generation: Int) async throws -> SupportTestimonialSlot
    func put(_ file: URL, slot: SupportTestimonialSlot, size: Int, generation: Int, progress: @escaping @Sendable (Double) -> Void) async throws
    func submit(_ id: String, uploadId: String, clientSubmissionId: String, publication: Bool, version: String, generation: Int) async throws -> AppReferTestimonialRequest
    func decline(_ id: String, dontAskAgain: Bool, generation: Int) async throws -> AppReferTestimonialRequest
}

struct LiveTestimonialTransport: TestimonialTransport {
    private func path(_ id: String, _ tail: String = "") -> String { "/api/support/v1/testimonials/\(id.urlPathEscaped)\(tail)" }
    private func decode(_ data: Data) throws -> AppReferTestimonialRequest { try JSONDecoder().decode(SupportTestimonialEnvelope.self, from: data).request }

    func request(_ id: String, generation: Int) async throws -> AppReferTestimonialRequest {
        try decode(try await SupportAPI.shared.sessionCall("GET", path(id), generation: generation))
    }
    func slot(_ id: String, contentType: String, size: Int, generation: Int) async throws -> SupportTestimonialSlot {
        let data = try await SupportAPI.shared.sessionCall("POST", path(id, "/uploads"), body: ["contentType": contentType, "size": size], generation: generation)
        return try JSONDecoder().decode(SupportTestimonialSlot.self, from: data)
    }
    func put(_ file: URL, slot: SupportTestimonialSlot, size: Int, generation: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: slot.uploadUrl), url.scheme == "https" else { throw AppReferSupportError(status: 0, message: "Bad upload address", reason: .upload) }
        let status = try await SupportAPI.shared.putFile(file, to: url, headers: slot.headers, size: size, generation: generation, progress: progress)
        guard (200..<300).contains(status) else { throw AppReferSupportError(status: status, message: "The upload didn't finish (\(status))", reason: .upload) }
    }
    func submit(_ id: String, uploadId: String, clientSubmissionId: String, publication: Bool, version: String, generation: Int) async throws -> AppReferTestimonialRequest {
        let body: [String: Any] = ["uploadId": uploadId, "clientSubmissionId": clientSubmissionId, "publication": publication, "permissionVersion": version]
        return try decode(try await SupportAPI.shared.sessionCall("POST", path(id, "/submit"), body: body, generation: generation))
    }
    func decline(_ id: String, dontAskAgain: Bool, generation: Int) async throws -> AppReferTestimonialRequest {
        try decode(try await SupportAPI.shared.sessionCall("POST", path(id, "/decline"), body: ["dontAskAgain": dontAskAgain], generation: generation))
    }
}

extension SupportAPI {
    func openTestimonials() async throws -> [AppReferTestimonialRequest] {
        try JSONDecoder().decode(SupportTestimonialList.self, from: try await sessionCall("GET", "/api/support/v1/testimonials")).requests
    }
    func revokeTestimonialPublication(_ id: String) async throws -> AppReferTestimonialRequest {
        let data = try await sessionCall("POST", "/api/support/v1/testimonials/\(id.urlPathEscaped)/permission", body: ["publication": "revoked"])
        return try JSONDecoder().decode(SupportTestimonialEnvelope.self, from: data).request
    }
}

/// Random id for one share attempt: the same on every retry, so a lost answer never shares twice.
func newTestimonialClientId() -> String { "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// `AppRefer.support.testimonials`: ask the customer for a photo or short video your backend
/// requested, from your own screens or your coach (`POST /api/v1/apps/{appId}/support/testimonials/requests`
/// returns the request id), and learn when the reward is confirmed.
@MainActor
public final class AppReferTestimonials {
    public static let shared = AppReferTestimonials()
    private init() {}

    /// Called when the SDK sees a request's reward state change (after a share, while the screen
    /// polls briefly, or from `rewardStatus(requestId:)`). On `fulfilled`, refresh credits/usage.
    public var onRewardUpdate: ((AppReferTestimonialRewardUpdate) -> Void)?
    private var lastReward: [String: String] = [:]
    private weak var presented: UIViewController?

    /// Whether this app can offer the camera (it declares the camera, and for video the
    /// microphone, usage text). The photo library is always offered (system picker, no prompt).
    public func cameraAvailable(video: Bool) -> Bool { TestimonialMedia.cameraAvailable(video: video) }

    /// Open requests for the verified account (empty when the session isn't verified).
    public func pending() async throws -> [AppReferTestimonialRequest] { try await SupportAPI.shared.openTestimonials() }

    /// One request; throws `AppReferSupportError` with code `IDENTITY_REQUIRED` until the app has
    /// verified this account, and 404 for another account's request.
    public func request(_ requestId: String) async throws -> AppReferTestimonialRequest {
        try await LiveTestimonialTransport().request(requestId, generation: SupportAPI.shared.actionGeneration)
    }

    /// The reward's state now; calls `onRewardUpdate` when it changed since the SDK last saw it.
    @discardableResult
    public func rewardStatus(requestId: String) async throws -> String {
        let r = try await request(requestId)
        let status = r.rewardStatus ?? "none"
        note(requestId: requestId, rewardStatus: status)
        return status
    }

    /// Withdraws permission for public use of something already shared. The reward is unaffected.
    public func withdrawPublication(requestId: String) async throws {
        _ = try await SupportAPI.shared.revokeTestimonialPublication(requestId)
    }

    /// Shows the capture screen for a request your backend made (sheet over the top screen).
    public func present(requestId: String, completion: ((AppReferTestimonialResult) -> Void)? = nil) {
        if let presented, presented.presentingViewController != nil { presented.dismiss(animated: false) }
        guard let top = Self.topViewController() else { return }
        var host: UIHostingController<AppReferTestimonialView>?
        let view = AppReferTestimonialView(requestId: requestId) { result in
            host?.dismiss(animated: true)
            completion?(result)
        }
        host = UIHostingController(rootView: view)
        host!.modalPresentationStyle = .pageSheet
        if let sheet = host!.sheetPresentationController { sheet.detents = [.large()]; sheet.prefersGrabberVisible = true }
        presented = host
        top.present(host!, animated: true)
    }

    func note(requestId: String, rewardStatus: String) {
        guard lastReward[requestId] != rewardStatus else { return }
        let first = lastReward[requestId] == nil
        lastReward[requestId] = rewardStatus
        // The first sighting of "none" (nothing earned yet) isn't a change worth telling the app.
        if first && rewardStatus == "none" { return }
        onRewardUpdate?(AppReferTestimonialRewardUpdate(requestId: requestId, rewardStatus: rewardStatus))
    }

    func reset() { lastReward.removeAll(); presented?.dismiss(animated: false); presented = nil }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

/// The capture flow's state, separate from the views so it can be tested without UI.
@MainActor
final class TestimonialFlowModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, uploading(Double), checking, done, unavailable, failed }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var request: AppReferTestimonialRequest?
    @Published private(set) var file: TestimonialFile?
    /// Public use starts on; the customer can turn it off. Nothing is recorded until `submit()`
    /// (opening, picking or cancelling sends no answer), and a request without permission text
    /// (an older server) can't be submitted, so no permission is ever assumed.
    @Published var publish = true
    /// The final button says what it sends: "Send and allow sharing" while the switch is on,
    /// "Send privately" while it is off (also on retry). Without permission text there is no
    /// switch and nothing can be submitted, so it keeps the plain label.
    var submitLabelKey: String {
        guard request?.permission != nil else { return "support.testimonial.submit" }
        return publish ? "support.testimonial.submitPublic" : "support.testimonial.submitPrivate"
    }
    /// The localized message for the last problem (nil when none).
    @Published private(set) var notice: String?

    let requestId: String
    private let transport: TestimonialTransport
    private let generation: Int
    private let clientSubmissionId = newTestimonialClientId()
    /// The upload of `file` that already reached storage (a retry only resubmits).
    private var uploaded: (file: URL, uploadId: String)?

    init(requestId: String, transport: TestimonialTransport = LiveTestimonialTransport(), generation: Int = SupportAPI.shared.actionGeneration) {
        self.requestId = requestId
        self.transport = transport
        self.generation = generation
    }

    func load() async {
        do {
            let r = try await transport.request(requestId, generation: generation)
            request = r
            phase = r.isOpen ? .ready : r.status == "submitted" ? .done : .unavailable
            if r.status == "submitted" { AppReferTestimonials.shared.note(requestId: requestId, rewardStatus: r.rewardStatus ?? "none") }
        } catch {
            notice = Self.message(for: error)
            phase = (error as? AppReferSupportError).map { $0.status == 404 || $0.code == "IDENTITY_REQUIRED" } == true ? .unavailable : .failed
        }
    }

    func picked(_ result: Result<TestimonialFile, TestimonialMediaError>) {
        switch result {
        case .success(let f):
            discardFile()
            file = f
            notice = nil
            if phase == .failed { phase = .ready }
        case .failure(.cancelled):
            break
        case .failure(.tooLong(let seconds)):
            notice = SupportStrings.text("support.testimonial.tooLong", ["seconds": String(seconds)])
        case .failure(.tooLarge):
            notice = SupportStrings.text("support.testimonial.tooLarge")
        case .failure(.unreadable):
            notice = SupportStrings.text("support.error.imageUnreadable")
        }
    }

    /// Uploads (unless this file already reached storage) and shares. Safe to call again after a failure.
    func submit() async {
        guard let request, let file, let version = request.permission?.version else { return }
        notice = nil
        do {
            let uploadId: String
            if let done = uploaded, done.file == file.url {
                uploadId = done.uploadId
            } else {
                phase = .uploading(0)
                let slot = try await transport.slot(requestId, contentType: file.contentType, size: file.size, generation: generation)
                try await transport.put(file.url, slot: slot, size: file.size, generation: generation) { [weak self] p in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .uploading = self.phase { self.phase = .uploading(p) }
                    }
                }
                uploaded = (file.url, slot.uploadId)
                uploadId = slot.uploadId
            }
            phase = .checking
            let r = try await transport.submit(requestId, uploadId: uploadId, clientSubmissionId: clientSubmissionId, publication: publish, version: version, generation: generation)
            self.request = r
            phase = .done
            discardFile(keepUpload: true)
            AppReferTestimonials.shared.note(requestId: requestId, rewardStatus: r.rewardStatus ?? "none")
        } catch is CancellationError {
            phase = .unavailable
        } catch {
            let code = (error as? AppReferSupportError)?.code
            // The file itself was refused: a new file is needed, so a retry must upload again.
            if ["TYPE_MISMATCH", "UNREADABLE_VIDEO", "VIDEO_TOO_LONG", "UPLOAD_INCOMPLETE", "UPLOAD_CHANGED", "UNKNOWN_UPLOAD"].contains(code ?? "") { uploaded = nil }
            if ["REQUEST_CLOSED", "CAMPAIGN_ENDED", "IDENTITY_REQUIRED", "ALREADY_SUBMITTED"].contains(code ?? "") || (error as? AppReferSupportError)?.status == 404 {
                notice = SupportStrings.text("support.testimonial.unavailable")
                phase = .unavailable
            } else {
                notice = code == "VIDEO_TOO_LONG" ? SupportStrings.text("support.testimonial.tooLong", ["seconds": String(request.maxVideoSeconds ?? 0)])
                    : code == "TOO_LARGE" ? SupportStrings.text("support.testimonial.tooLarge") : SupportStrings.text("support.testimonial.failed")
                phase = .failed
            }
        }
    }

    func decline(dontAskAgain: Bool) async -> AppReferTestimonialResult {
        let r = try? await transport.decline(requestId, dontAskAgain: dontAskAgain, generation: generation)
        discardFile()
        return AppReferTestimonialResult(requestId: requestId, outcome: .declined, rewardStatus: r?.rewardStatus, publication: nil)
    }

    /// While the done screen is open: check the reward a few times (the app's backend applies it).
    func followReward() async {
        for delay in [3, 5, 8, 13, 21] as [UInt64] {
            guard phase == .done, let status = request?.rewardStatus, status == "pending" || status == "delivered" else { return }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let r = try? await transport.request(requestId, generation: generation) else { return }
            request = r
            AppReferTestimonials.shared.note(requestId: requestId, rewardStatus: r.rewardStatus ?? "none")
        }
    }

    var result: AppReferTestimonialResult {
        let outcome: AppReferTestimonialResult.Outcome = phase == .done ? .submitted : phase == .unavailable ? .unavailable : .cancelled
        return AppReferTestimonialResult(requestId: requestId, outcome: outcome, rewardStatus: request?.rewardStatus, publication: request?.publication)
    }

    func discardFile(keepUpload: Bool = false) {
        if let f = file { try? FileManager.default.removeItem(at: f.url) }
        file = nil
        if !keepUpload { uploaded = nil }
    }

    static func message(for error: Error) -> String {
        if let e = error as? AppReferSupportError, e.status == 404 || e.code == "IDENTITY_REQUIRED" { return SupportStrings.text("support.testimonial.unavailable") }
        return SupportStrings.text("support.testimonial.failed")
    }
}

/// The capture screen: what's asked, the reward, pick or record, preview, the public-use switch
/// (on unless the customer turns it off) with the app's exact permission text, honest progress, then the result. Embed it, or let
/// `AppRefer.support.testimonials.present(requestId:)` show it.
public struct AppReferTestimonialView: View {
    @StateObject private var model: TestimonialFlowModel
    private let onFinish: (AppReferTestimonialResult) -> Void
    @State private var host: UIViewController?
    private var palette: SupportPalette { SupportPalette(AppReferSupport.shared.accentColor ?? .accentColor) }

    public init(requestId: String, onFinish: @escaping (AppReferTestimonialResult) -> Void) {
        _model = StateObject(wrappedValue: TestimonialFlowModel(requestId: requestId))
        self.onFinish = onFinish
    }

    init(model: TestimonialFlowModel, onFinish: @escaping (AppReferTestimonialResult) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onFinish = onFinish
    }

    public var body: some View {
        TestimonialScreen(model: model, palette: palette, finish: { onFinish(model.result) }, decline: { dontAsk in
            Task { onFinish(await model.decline(dontAskAgain: dontAsk)) }
        }, pick: { camera in pick(camera: camera) })
        .task { await model.load() }
        .background(TestimonialHostFinder { host = $0 })
        .onDisappear { model.discardFile() }
    }

    private func pick(camera: Bool) {
        guard let r = model.request, let from = host ?? AppReferTestimonials.topViewController() else { return }
        let seconds = r.maxVideoSeconds ?? 30
        if camera {
            TestimonialPicker.camera(from: from, images: r.allowsImages, videos: r.allowsVideos && TestimonialMedia.cameraAvailable(video: true), maxSeconds: seconds) { model.picked($0) }
        } else {
            TestimonialPicker.library(from: from, images: r.allowsImages, videos: r.allowsVideos, maxSeconds: seconds) { model.picked($0) }
        }
    }
}

/// The screen itself, driven by a model (also rendered from fixtures in tests).
struct TestimonialScreen: View {
    @ObservedObject var model: TestimonialFlowModel
    let palette: SupportPalette
    let finish: () -> Void
    let decline: (Bool) -> Void
    let pick: (Bool) -> Void
    var cameraImages = TestimonialMedia.cameraAvailable(video: false)
    var cameraVideos = TestimonialMedia.cameraAvailable(video: true)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: finish) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                        .frame(width: 36, height: 36).background(Color.primary.opacity(0.06), in: Circle())
                }
                .accessibilityLabel(SupportStrings.text("support.testimonial.cancel"))
                .disabled(busy)
            }
            .padding(.horizontal, 16).padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.horizontal, 20).padding(.bottom, 28)
            }
        }
        .background(SupportColors.background.ignoresSafeArea())
        .interactiveDismissDisabled(busy)
    }

    private var busy: Bool { if case .uploading = model.phase { return true }; return model.phase == .checking }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        case .unavailable:
            info(SupportStrings.text("support.testimonial.unavailable"), symbol: "info.circle")
            primary(SupportStrings.text("support.testimonial.cancel"), action: finish)
        case .done:
            done
        case .ready, .uploading, .checking, .failed:
            if let r = model.request { form(r) } else {
                info(model.notice ?? SupportStrings.text("support.testimonial.failed"), symbol: "wifi.exclamationmark")
                primary(SupportStrings.text("support.action.tryAgain")) { Task { await model.load() } }
            }
        }
    }

    @ViewBuilder private func form(_ r: AppReferTestimonialRequest) -> some View {
        Text(r.title ?? SupportStrings.text("support.testimonial.open")).font(.system(size: 26, weight: .bold)).accessibilityAddTraits(.isHeader)
        if let prompt = r.prompt { Text(prompt).font(.system(size: 16)).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true) }
        Text(SupportStrings.text("support.testimonial.honest")).font(.system(size: 14)).foregroundStyle(SupportColors.muted).fixedSize(horizontal: false, vertical: true)
        if let reward = r.reward?.description { rewardBox(reward) }
        if let file = model.file {
            TestimonialPreview(file: file).frame(maxWidth: .infinity).frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityLabel(SupportStrings.text("support.testimonial.a11y.preview"))
            if !busy { secondary(SupportStrings.text("support.testimonial.retake")) { pick(false) } }
            if let permission = r.permission { publishToggle(permission) }
        } else {
            VStack(spacing: 10) {
                primary(SupportStrings.text("support.testimonial.choose"), symbol: "photo.on.rectangle") { pick(false) }
                if (r.allowsImages && cameraImages) || (r.allowsVideos && cameraVideos) {
                    secondary(SupportStrings.text("support.testimonial.camera"), symbol: "camera") { pick(true) }
                }
            }
            if let seconds = r.maxVideoSeconds, r.allowsVideos {
                Text(SupportStrings.text("support.testimonial.tooLong", ["seconds": String(seconds)])).font(.system(size: 13)).foregroundStyle(SupportColors.muted)
            }
        }
        if let notice = model.notice { info(notice, symbol: "exclamationmark.circle") }
        switch model.phase {
        case .uploading(let p):
            ProgressView(value: p).tint(palette.accent)
            Text(SupportStrings.text("support.testimonial.uploading", ["percent": String(Int((p * 100).rounded()))])).font(.system(size: 14)).foregroundStyle(SupportColors.muted)
        case .checking:
            HStack(spacing: 8) { ProgressView(); Text(SupportStrings.text("support.testimonial.checking")).foregroundStyle(SupportColors.muted) }
        default:
            if model.file != nil {
                primary(SupportStrings.text(model.submitLabelKey)) { Task { await model.submit() } }
            }
            HStack(spacing: 18) {
                Button(SupportStrings.text("support.testimonial.decline")) { decline(false) }
                Button(SupportStrings.text("support.testimonial.dontAsk")) { decline(true) }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(SupportColors.muted).frame(maxWidth: .infinity)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(palette.accent).accessibilityHidden(true)
            Text(SupportStrings.text("support.testimonial.done")).font(.system(size: 26, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let request = model.request, let reward = request.reward?.description {
                rewardBox(reward)
                Text(SupportStrings.text(request.rewardStatusKey)).font(.system(size: 15)).foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            primary(SupportStrings.text("support.a11y.close"), action: finish)
        }
        .task { await model.followReward() }
    }

    private func rewardBox(_ reward: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(SupportStrings.text("support.testimonial.reward", ["reward": reward]), systemImage: "gift").font(.system(size: 15, weight: .semibold))
            Text(SupportStrings.text("support.testimonial.rewardNote")).font(.system(size: 13)).foregroundStyle(SupportColors.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func publishToggle(_ p: AppReferTestimonialRequest.Permission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(SupportStrings.text("support.testimonial.publish"), isOn: $model.publish).font(.system(size: 15, weight: .semibold)).tint(palette.accent).disabled(busy)
            Text(p.text).font(.system(size: 13.5)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            Text(SupportStrings.text("support.testimonial.publishHint")).font(.system(size: 12.5)).foregroundStyle(SupportColors.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).background(SupportColors.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func info(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14)).foregroundStyle(SupportColors.muted)
    }

    private func primary(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { if let symbol { Image(systemName: symbol) }; Text(title).font(.system(size: 16, weight: .semibold)) }
                .foregroundStyle(palette.onAccent).frame(maxWidth: .infinity, minHeight: 50).background(palette.bubble, in: Capsule())
        }
        .buttonStyle(SupportPressStyle())
    }

    private func secondary(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { if let symbol { Image(systemName: symbol) }; Text(title).font(.system(size: 15.5, weight: .semibold)) }
                .foregroundStyle(palette.accent).frame(maxWidth: .infinity, minHeight: 46).background(palette.accent.opacity(0.1), in: Capsule())
        }
        .buttonStyle(SupportPressStyle())
    }
}

/// A still for a photo; the first frame for a video (no autoplay).
struct TestimonialPreview: View {
    let file: TestimonialFile
    var body: some View {
        if let image = file.kind == "image" ? UIImage(contentsOfFile: file.url.path) : Self.firstFrame(file.url) {
            ZStack {
                Color.black
                Image(uiImage: image).resizable().scaledToFit()
                if file.kind == "video" { Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.9)) }
            }
        } else {
            Color.primary.opacity(0.06)
        }
    }

    static func firstFrame(_ url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init(cgImage:))
    }
}

/// Finds the view controller hosting the screen, to present pickers over it.
private struct TestimonialHostFinder: UIViewControllerRepresentable {
    let found: (UIViewController) -> Void
    func makeUIViewController(context: Context) -> UIViewController { Finder(found: found) }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    final class Finder: UIViewController {
        let found: (UIViewController) -> Void
        init(found: @escaping (UIViewController) -> Void) { self.found = found; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { nil }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); if let p = parent { found(p) } }
    }
}

/// Which request the chat's capture sheet shows.
struct SupportCaptureTarget: Identifiable, Equatable { let id: String }

/// The request card under a team message in the chat.
struct SupportTestimonialCardView: View {
    let request: AppReferTestimonialRequest
    let palette: SupportPalette
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(request.isOpen ? palette.accent : SupportColors.muted)
                    .frame(width: 26, height: 26)
                    .background((request.isOpen ? palette.accent : SupportColors.muted).opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                Text(request.title ?? SupportStrings.text("support.testimonial.open")).font(.system(size: 15, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            if request.isOpen {
                if let prompt = request.prompt { Text(prompt).font(.system(size: 14.5)).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true) }
                Text(SupportStrings.text("support.testimonial.honest")).font(.system(size: 13)).foregroundStyle(SupportColors.muted).fixedSize(horizontal: false, vertical: true)
                if let reward = request.reward?.description {
                    Text(SupportStrings.text("support.testimonial.reward", ["reward": reward])).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(palette.accent)
                }
                Button(action: open) {
                    Text(SupportStrings.text("support.testimonial.open")).font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.onAccent).frame(maxWidth: .infinity, minHeight: 46).background(palette.bubble, in: Capsule())
                }
                .buttonStyle(SupportPressStyle())
            } else {
                Text(SupportStrings.text(request.status == "submitted" ? "support.testimonial.done" : "support.testimonial.unavailable"))
                    .font(.system(size: 13.5)).foregroundStyle(SupportColors.muted)
            }
        }
        .padding(14)
        .background(SupportColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(request.isOpen ? palette.accent.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: SupportColors.shadow.opacity(0.07), radius: 10, y: 3)
    }
}
#endif
