import XCTest
#if os(iOS)
import SwiftUI
#endif
@testable import AppRefer
#if canImport(UIKit)
import UIKit
#endif

final class SupportTests: XCTestCase {
    func testDecodesThreadAndMessages() throws {
        let json = """
        {"conversation":{"id":"c1","subject":"Charged twice","status":"open","preview":"x","lastMessageAt":"2026-10-15T10:00:00.000Z","lastFrom":"team","unread":1},
         "messages":[{"id":"m1","from":"customer","authorName":null,"text":"hi","createdAt":"2026-10-15T09:00:00.000Z","attachments":[]},
                     {"id":"m2","from":"team","authorName":"Jay Patel","text":"","createdAt":"2026-10-15T10:00:00Z","attachments":[{"url":"https://x/y.jpg","name":"y.jpg","contentType":"image/jpeg","size":12}]}]}
        """
        let thread = try JSONDecoder().decode(SupportThread.self, from: Data(json.utf8))
        XCTAssertEqual(thread.conversation.unread, 1)
        XCTAssertTrue(thread.messages[0].isFromCustomer)
        XCTAssertNotNil(thread.messages[0].date)
        XCTAssertNotNil(thread.messages[1].date, "dates without fractions parse too")
        XCTAssertTrue(thread.messages[1].attachments[0].isImage)
    }

    func testContextNamesAppDeviceAndOS() {
        let c = SupportAPI.context()
        XCTAssertNotNil(c["device"] as? String)
        XCTAssertTrue((c["os"] as? String)?.hasPrefix("iOS ") ?? false)
        XCTAssertNotNil(c["locale"] as? String)
    }

    func testPathAndQueryEscaping() {
        XCTAssertEqual("a/b c".urlPathEscaped, "a%2Fb%20c")
        XCTAssertEqual("2026-10-15T10:00:00.000+01:00".addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed), "2026-10-15T10:00:00.000%2B01:00")
    }

    #if os(iOS)
    func testScreenshotsShrinkBeforeUpload() {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 6000)).image { ctx in
            for i in 0..<300 {
                UIColor(hue: CGFloat(i) / 300, saturation: 1, brightness: 1, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: i * 20, width: 3000, height: 20))
            }
        }
        let data = SupportImages.jpeg(big)
        XCTAssertLessThanOrEqual(data.count, 700_000)
        let decoded = UIImage(data: data)!
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 1600)
    }
    #endif

    #if os(iOS)
    func testTextOnABrightAccentIsDark() {
        XCTAssertEqual(SupportPalette(Color(red: 1, green: 0.84, blue: 0.1)).onAccent, Color(white: 0.08))
        XCTAssertEqual(SupportPalette(Color(red: 0.43, green: 0.29, blue: 1)).onAccent, .white)
    }

    @MainActor
    func testHeaderStyleDefaultsToAccent() {
        XCTAssertEqual(AppReferSupport.shared.headerStyle, .accent)
        XCTAssertEqual(AppReferSupportHeaderStyle.allCases, [.accent, .plain])
    }

    func testAccentHeaderKeepsTheExistingLook() {
        for accent in [Color(red: 0.47, green: 0.32, blue: 1), .white, Color(red: 1, green: 0.84, blue: 0.04)] {
            let p = SupportPalette(accent)
            for dark in [true, false] {
                let look = SupportHeaderLook(.accent, palette: p, dark: dark)
                XCTAssertFalse(look.plain)
                XCTAssertTrue(look.glows)
                XCTAssertEqual(look.background, p.accent)
                XCTAssertEqual(look.foreground, p.onAccent)
                XCTAssertEqual(look.closeTint, p.onAccent.opacity(0.12))
                XCTAssertEqual(look.pillFill, Color.black.opacity(p.onAccent == .white ? 0.16 : 0.06))
                XCTAssertEqual(look.pillStroke, p.onAccent.opacity(0.3))
                XCTAssertNil(look.avatars)
                XCTAssertEqual(look.iconText, p.light)
            }
        }
    }

    private func rgb(_ c: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private func isNeutral(_ c: Color) -> Bool {
        let (r, g, b, _) = rgb(c)
        return abs(r - g) < 0.002 && abs(g - b) < 0.002
    }

    private func contrast(_ x: Color, _ y: Color) -> CGFloat {
        func lum(_ c: Color) -> CGFloat {
            let (r, g, b, _) = rgb(c)
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let (a, b) = (lum(x), lum(y))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testWhiteAccentGlowsAreTinted() {
        // Why `.plain` exists: a white accent's glow colours are not grey (the green/lavender glow).
        let p = SupportPalette(.white)
        XCTAssertFalse(isNeutral(p.hot) && isNeutral(p.warm))
    }

    func testPlainHeaderIsNeutralWithReadableText() {
        for accent in [Color(red: 0.47, green: 0.32, blue: 1), .white, Color(red: 1, green: 0.84, blue: 0.04), Color(red: 0.12, green: 0.72, blue: 0.4)] {
            let p = SupportPalette(accent)
            for dark in [true, false] {
                let look = SupportHeaderLook(.plain, palette: p, dark: dark)
                XCTAssertTrue(look.plain)
                XCTAssertFalse(look.glows, "no glow overlays")
                for c in [look.background, look.foreground, look.closeTint, look.pillFill, look.pillStroke, look.avatarRing, look.iconText] + (look.avatars ?? []) + look.iconTile {
                    XCTAssertTrue(isNeutral(c))
                }
                XCTAssertEqual(rgb(look.background).0, SupportHeaderLook.plainWhite(dark: dark), accuracy: 0.002)
                XCTAssertEqual(rgb(look.foreground).0, dark ? 1 : 0.07, accuracy: 0.002)
                XCTAssertGreaterThanOrEqual(contrast(look.foreground, look.background), 4.5)
                for avatar in look.avatars ?? [] { XCTAssertGreaterThanOrEqual(contrast(.white, avatar), 4.5) }
            }
        }
    }

    @MainActor
    func testContinueCardPicksUnreadThenNewestOpen() {
        func conv(_ id: String, _ status: String, _ at: String, unread: Int = 0) -> AppReferSupportConversation {
            try! JSONDecoder().decode(AppReferSupportConversation.self, from: Data("""
            {"id":"\(id)","subject":"s","status":"\(status)","preview":"p","lastMessageAt":"\(at)","lastFrom":"team","unread":\(unread)}
            """.utf8))
        }
        let model = SupportHomeModel()
        model.conversations = [conv("a", "open", "2026-10-15T10:00:00Z"), conv("b", "closed", "2026-10-15T12:00:00Z"), conv("c", "open", "2026-10-15T11:00:00Z")]
        XCTAssertEqual(model.current?.id, "c")
        XCTAssertEqual(model.others.map(\.id), ["a", "b"])
        model.conversations.append(conv("d", "open", "2026-10-14T09:00:00Z", unread: 1))
        XCTAssertEqual(model.current?.id, "d")
    }
    #endif
}
