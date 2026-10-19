import XCTest
@testable import AppRefer
#if os(iOS)
import UIKit

/// Stands in for the network in the capture flow and records what was asked.
private final class FakeTransport: TestimonialTransport, @unchecked Sendable {
    let lock = NSLock()
    var request: AppReferTestimonialRequest
    var slots = 0
    var puts = 0
    var submits: [(uploadId: String, client: String, publication: Bool, version: String)] = []
    var failSubmitOnce: AppReferSupportError?
    var failPut = false
    init(_ request: AppReferTestimonialRequest) { self.request = request }

    func request(_ id: String, generation: Int) async throws -> AppReferTestimonialRequest { request }
    func slot(_ id: String, contentType: String, size: Int, generation: Int) async throws -> SupportTestimonialSlot {
        lock.lock(); slots += 1; let n = slots; lock.unlock()
        return SupportTestimonialSlot(uploadId: "tup_\(String(repeating: "0", count: 31))\(n)", uploadUrl: "https://r2.test/u", headers: ["Content-Type": contentType])
    }
    func put(_ file: URL, slot: SupportTestimonialSlot, size: Int, generation: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        if failPut { throw AppReferSupportError(status: 0, message: "offline", reason: .upload) }
        lock.lock(); puts += 1; lock.unlock()
        progress(0.5); progress(1)
    }
    func submit(_ id: String, uploadId: String, clientSubmissionId: String, publication: Bool, version: String, generation: Int) async throws -> AppReferTestimonialRequest {
        lock.lock(); submits.append((uploadId, clientSubmissionId, publication, version)); let fail = failSubmitOnce; failSubmitOnce = nil; lock.unlock()
        if let fail { throw fail }
        return Self.decode(Self.json(status: "submitted", rewardStatus: "pending", publication: publication ? "granted" : "declined"))
    }
    func decline(_ id: String, dontAskAgain: Bool, generation: Int) async throws -> AppReferTestimonialRequest {
        Self.decode(Self.json(status: "declined", rewardStatus: "none"))
    }

    static func json(status: String = "open", rewardStatus: String = "none", publication: String? = nil, media: String = #"["image","video"]"#) -> String {
        #"{"requestId":"tsr_0123456789abcdef0123456789abcdef","campaignId":"progress_story","status":"\#(status)","title":"Share your progress","prompt":"Show us what you made.","media":\#(media),"maxVideoSeconds":30,"maxImageBytes":15728640,"maxVideoBytes":157286400,"reward":{"type":"credits","description":"50 bonus credits"},"permission":{"text":"You may show this in the app.","scopes":["in_app"],"version":"0123456789abcdef"},"expiresAt":"2026-11-02T12:00:00.000Z","submittedAt":null,"submission":null,"publication":\#(publication.map { "\"\($0)\"" } ?? "null"),"rewardStatus":"\#(rewardStatus)"}"#
    }
    static func decode(_ json: String) -> AppReferTestimonialRequest { try! JSONDecoder().decode(AppReferTestimonialRequest.self, from: Data(json.utf8)) }
}

@MainActor
final class SupportTestimonialTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SupportStrings.forcedLanguage = "en"
        AppReferTestimonials.shared.reset()
        AppReferTestimonials.shared.onRewardUpdate = nil
    }
    override func tearDown() {
        SupportStrings.forcedLanguage = nil
        AppReferTestimonials.shared.onRewardUpdate = nil
        super.tearDown()
    }

    private func jpegFile() throws -> TestimonialFile {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30)) }
        return try TestimonialMedia.normalizeImage(image)
    }

    func testDecodesTheServerShapesIncludingUnavailableCards() throws {
        let full = FakeTransport.decode(FakeTransport.json())
        XCTAssertTrue(full.isOpen && full.allowsImages && full.allowsVideos)
        XCTAssertEqual(full.reward?.description, "50 bonus credits")
        let card = try JSONDecoder().decode(AppReferTestimonialRequest.self, from: Data(#"{"requestId":"tsr_x","status":"unavailable"}"#.utf8))
        XCTAssertFalse(card.isOpen)
        XCTAssertNil(card.reward)
        let message = try JSONDecoder().decode(AppReferSupportMessage.self, from: Data(#"{"id":"m1","from":"team","authorName":"Jay","text":"Would you share one?","createdAt":"2026-10-19T12:00:00.000Z","attachments":[],"testimonial":\#(FakeTransport.json())}"#.utf8))
        XCTAssertEqual(message.testimonial?.requestId, "tsr_0123456789abcdef0123456789abcdef")
    }

    func testTheChatTellsTheServerItRunsTheCaptureFlow() {
        SupportOfferHandlerFlag.shared.set(false)
        XCTAssertTrue(SupportOfferHandlerFlag.shared.header.contains("testimonials"))
    }

    func testPhotosAreReencodedAsJpegWithoutMetadata() throws {
        let file = try jpegFile()
        defer { try? FileManager.default.removeItem(at: file.url) }
        let data = try Data(contentsOf: file.url)
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertEqual(file.contentType, "image/jpeg")
        XCTAssertEqual(file.size, data.count)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil) as? [String: Any]
        XCTAssertNil(props?[kCGImagePropertyGPSDictionary as String], "no location")
    }

    func testTheCameraIsOfferedOnlyWithTheUsageTextsTheSystemRequires() {
        // Without the usage texts the system would end the app on opening the camera: never offered.
        XCTAssertFalse(TestimonialMedia.cameraAvailable(video: false, info: [:]))
        XCTAssertFalse(TestimonialMedia.cameraAvailable(video: true, info: ["NSCameraUsageDescription": "x"]), "video also needs the microphone text")
    }

    func testShareUploadsOnceAndALostAnswerResubmitsTheSameUpload() async throws {
        let transport = FakeTransport(FakeTransport.decode(FakeTransport.json()))
        let model = TestimonialFlowModel(requestId: "tsr_0123456789abcdef0123456789abcdef", transport: transport, generation: 0)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        model.picked(.success(try jpegFile()))
        model.publish = false
        transport.failSubmitOnce = AppReferSupportError(status: 0, message: "The network connection was lost.")
        await model.submit()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.notice, "Couldn't share it, nothing was sent. Check your connection and try again.")
        await model.submit()
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(transport.slots, 1, "the file reached storage once; the retry only resubmits")
        XCTAssertEqual(transport.puts, 1)
        XCTAssertEqual(transport.submits.count, 2)
        XCTAssertEqual(transport.submits[0].uploadId, transport.submits[1].uploadId)
        XCTAssertEqual(transport.submits[0].client, transport.submits[1].client, "same clientSubmissionId: the server answers the retry with the first result")
        XCTAssertFalse(transport.submits[1].publication)
        XCTAssertEqual(transport.submits[1].version, "0123456789abcdef")
        XCTAssertEqual(model.result.outcome, .submitted)
        XCTAssertEqual(model.result.rewardStatus, "pending")
    }

    func testPublicUseStartsOnButOnlyTheFinalShareRecordsIt() async throws {
        let transport = FakeTransport(FakeTransport.decode(FakeTransport.json()))
        let model = TestimonialFlowModel(requestId: "tsr_0123456789abcdef0123456789abcdef", transport: transport, generation: 0)
        XCTAssertTrue(model.publish, "public use starts on")
        await model.load()
        model.picked(.success(try jpegFile()))
        XCTAssertEqual(model.request?.permission?.text, "You may show this in the app.", "the app's registered text is what the switch shows")
        XCTAssertTrue(transport.submits.isEmpty, "opening and picking record nothing")
        await model.submit()
        XCTAssertEqual(transport.submits.count, 1)
        XCTAssertTrue(transport.submits[0].publication, "left on: the share says yes, with the version shown")
        XCTAssertEqual(transport.submits[0].version, "0123456789abcdef")
        XCTAssertEqual(model.result.publication, "granted")
        XCTAssertEqual(model.result.rewardStatus, "pending", "same reward path whether on or off")

        let declined = TestimonialFlowModel(requestId: "tsr_x", transport: FakeTransport(FakeTransport.decode(FakeTransport.json())), generation: 0)
        await declined.load()
        declined.picked(.success(try jpegFile()))
        let result = await declined.decline(dontAskAgain: false)
        XCTAssertNil(result.publication, "declining sends no permission answer")
    }

    func testTheSubmitButtonSaysWhetherItAllowsSharing() async throws {
        let transport = FakeTransport(FakeTransport.decode(FakeTransport.json()))
        transport.failSubmitOnce = AppReferSupportError(status: 0, message: "The network connection was lost.")
        let model = TestimonialFlowModel(requestId: "tsr_0123456789abcdef0123456789abcdef", transport: transport, generation: 0)
        await model.load()
        model.picked(.success(try jpegFile()))
        XCTAssertEqual(model.submitLabelKey, "support.testimonial.submitPublic")
        XCTAssertEqual(SupportStrings.text(model.submitLabelKey), "Send and allow sharing")
        model.publish = false
        XCTAssertEqual(SupportStrings.text(model.submitLabelKey), "Send privately")
        await model.submit()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(SupportStrings.text(model.submitLabelKey), "Send privately", "a retry still names what it sends")
        await model.submit()
        XCTAssertEqual(transport.submits.map(\.publication), [false, false], "the label matches the answer sent")
        SupportStrings.forcedLanguage = "de"
        XCTAssertEqual(SupportStrings.text("support.testimonial.submitPublic"), "Senden und Teilen erlauben")
        XCTAssertEqual(SupportStrings.text("support.testimonial.submitPrivate"), "Privat senden")
    }

    func testARequestWithoutPermissionTextIsNeverSubmittedWithAnAssumedAnswer() async throws {
        let old = FakeTransport.json().replacingOccurrences(of: #""permission":{"text":"You may show this in the app.","scopes":["in_app"],"version":"0123456789abcdef"},"#, with: "")
        let transport = FakeTransport(FakeTransport.decode(old))
        let model = TestimonialFlowModel(requestId: "tsr_x", transport: transport, generation: 0)
        await model.load()
        XCTAssertNil(model.request?.permission)
        XCTAssertEqual(model.submitLabelKey, "support.testimonial.submit", "no switch, so the button claims neither sharing nor privacy")
        model.picked(.success(try jpegFile()))
        await model.submit()
        XCTAssertTrue(transport.submits.isEmpty, "no permission text means no answer is sent or inferred")
        XCTAssertEqual(transport.slots, 0)
    }

    func testARefusedFileNeedsANewUploadAndAClosedRequestEndsTheFlow() async throws {
        let transport = FakeTransport(FakeTransport.decode(FakeTransport.json()))
        let model = TestimonialFlowModel(requestId: "tsr_x", transport: transport, generation: 0)
        await model.load()
        model.picked(.success(try jpegFile()))
        transport.failSubmitOnce = AppReferSupportError(status: 422, message: "The file isn't a supported photo or video.", code: "TYPE_MISMATCH")
        await model.submit()
        XCTAssertEqual(model.phase, .failed)
        await model.submit()
        XCTAssertEqual(transport.slots, 2, "a refused file is uploaded again, never resubmitted")
        let closed = TestimonialFlowModel(requestId: "tsr_y", transport: transport, generation: 0)
        await closed.load()
        closed.picked(.success(try jpegFile()))
        transport.failSubmitOnce = AppReferSupportError(status: 409, message: "account changed", code: "IDENTITY_REQUIRED")
        await closed.submit()
        XCTAssertEqual(closed.phase, .unavailable)
        XCTAssertEqual(closed.notice, "This request is no longer available")
    }

    func testPickerErrorsAreExplainedAndDeclineReportsNoReward() async throws {
        let transport = FakeTransport(FakeTransport.decode(FakeTransport.json()))
        let model = TestimonialFlowModel(requestId: "tsr_x", transport: transport, generation: 0)
        await model.load()
        model.picked(.failure(.tooLong(seconds: 30)))
        XCTAssertEqual(model.notice, "Videos can be up to 30 seconds.")
        model.picked(.failure(.tooLarge))
        XCTAssertEqual(model.notice, "This file is too large to share.")
        model.picked(.failure(.cancelled))
        XCTAssertNil(model.file)
        let result = await model.decline(dontAskAgain: true)
        XCTAssertEqual(result.outcome, .declined)
        XCTAssertEqual(result.rewardStatus, "none")
    }

    func testAnotherAccountsOrUnverifiedRequestShowsUnavailable() async {
        final class Refusing: TestimonialTransport, @unchecked Sendable {
            func request(_ id: String, generation: Int) async throws -> AppReferTestimonialRequest { throw AppReferSupportError(status: 409, message: "verify", code: "IDENTITY_REQUIRED") }
            func slot(_ id: String, contentType: String, size: Int, generation: Int) async throws -> SupportTestimonialSlot { fatalError() }
            func put(_ file: URL, slot: SupportTestimonialSlot, size: Int, generation: Int, progress: @escaping @Sendable (Double) -> Void) async throws { fatalError() }
            func submit(_ id: String, uploadId: String, clientSubmissionId: String, publication: Bool, version: String, generation: Int) async throws -> AppReferTestimonialRequest { fatalError() }
            func decline(_ id: String, dontAskAgain: Bool, generation: Int) async throws -> AppReferTestimonialRequest { fatalError() }
        }
        let model = TestimonialFlowModel(requestId: "tsr_x", transport: Refusing(), generation: 0)
        await model.load()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertEqual(model.result.outcome, .unavailable)
    }

    func testRewardUpdatesReachTheAppOncePerChange() {
        var seen: [String] = []
        AppReferTestimonials.shared.onRewardUpdate = { seen.append($0.rewardStatus) }
        AppReferTestimonials.shared.note(requestId: "tsr_a", rewardStatus: "none")
        AppReferTestimonials.shared.note(requestId: "tsr_a", rewardStatus: "pending")
        AppReferTestimonials.shared.note(requestId: "tsr_a", rewardStatus: "pending")
        AppReferTestimonials.shared.note(requestId: "tsr_a", rewardStatus: "fulfilled")
        XCTAssertEqual(seen, ["pending", "fulfilled"])
    }

    func testTheRewardLineFollowsTheBackendsReceiptAndTheRewardType() {
        func line(_ status: String, _ type: String) -> String {
            var json = FakeTransport.json(status: "submitted", rewardStatus: status)
            json = json.replacingOccurrences(of: #""type":"credits""#, with: #""type":"\#(type)""#)
            return SupportStrings.text(FakeTransport.decode(json).rewardStatusKey)
        }
        // Earned but unconfirmed: never "added".
        for status in ["pending", "delivered", "none"] {
            XCTAssertEqual(line(status, "credits"), "You've earned it. It shows as confirmed here once it has been applied.")
        }
        for type in ["credits", "coach_usage", "subscription_time"] {
            XCTAssertEqual(line("fulfilled", type), "Your reward has been added to your account.")
        }
        // Goods, gifts and discounts are handled by the app: confirmed, no shipping or email promise.
        for type in ["merch", "gift", "discount", "manual"] { XCTAssertEqual(line("fulfilled", type), "Your reward is confirmed.") }
        XCTAssertEqual(line("failed", "merch"), "Your reward hasn't been confirmed yet. Support can see this and can send it again.")
        XCTAssertEqual(line("timed_out", "credits"), line("failed", "merch"))
        XCTAssertEqual(line("not_eligible", "credits"), "You've already taken part in this, so there's no new reward this time.")
    }

    func testEveryLanguageHasTheTestimonialStrings() {
        let keys = SupportStrings.table("en").keys.filter { $0.hasPrefix("support.testimonial.") }
        XCTAssertEqual(keys.count, 32)
        for language in SupportStrings.supportedLanguages {
            let table = SupportStrings.table(language)
            for key in keys { XCTAssertNotNil(table[key], "\(language) lacks \(key)") }
            XCTAssertTrue(table["support.testimonial.reward"]?.contains("{reward}") == true, language)
            XCTAssertTrue(table["support.testimonial.tooLong"]?.contains("{seconds}") == true, language)
        }
    }
}
#endif
