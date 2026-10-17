import XCTest
@testable import AppRefer

final class SupportLocalizationTests: XCTestCase {
    override func tearDown() {
        SupportStrings.overrides = [:]
        SupportStrings.forcedLanguage = nil
        super.tearDown()
    }

    private func placeholders(_ text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: "\\{(\\w+)\\}")
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range(at: 1), in: text)!]) })
    }

    /// Plural keys in the English table, without their `#category`.
    private var pluralKeys: Set<String> {
        Set(SupportStrings.table("en").keys.filter { $0.contains("#") }.map { String($0.split(separator: "#")[0]) })
    }

    // MARK: - Catalogue

    func testEveryLanguageShipsAndEnglishHasTheWholeKeySet() {
        let shipped = Set(Bundle.module.localizations.filter { $0 != "Base" }.map { $0 })
        for language in SupportStrings.supportedLanguages {
            XCTAssertTrue(shipped.contains(language) || !SupportStrings.table(language).isEmpty, "\(language).lproj is missing")
        }
        XCTAssertEqual(SupportStrings.supportedLanguages.count, 35)
        let english = SupportStrings.table("en")
        XCTAssertGreaterThanOrEqual(english.count, 78)
        for key in ["support.home.subtitle", "support.ai.tag", "support.a11y.unread#one", "support.a11y.unread#other", "support.error.offline"] {
            XCTAssertNotNil(english[key], key)
        }
    }

    func testEveryKeyIsTranslatedInEveryLanguageWithItsPlaceholders() {
        let english = SupportStrings.table("en")
        let singular = english.filter { !$0.key.contains("#") }
        let plurals = pluralKeys
        let counts = Array(0...230) + [1_000, 1_001, 1_000_000, 2_000_000]
        for language in SupportStrings.supportedLanguages {
            let table = SupportStrings.table(language)
            XCTAssertFalse(table.isEmpty, "\(language) has no table")
            for (key, source) in singular {
                guard let text = table[key] else { XCTFail("\(language): missing \(key)"); continue }
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): empty \(key)")
                XCTAssertEqual(placeholders(text), placeholders(source), "\(language): placeholders of \(key)")
            }
            for key in plurals {
                let needed = Set(counts.map { SupportStrings.pluralCategory($0, language: language) })
                for category in needed {
                    guard let text = table["\(key)#\(category)"] else { XCTFail("\(language): missing \(key)#\(category)"); continue }
                    XCTAssertEqual(placeholders(text), ["count"], "\(language): placeholders of \(key)#\(category)")
                }
            }
            // Nothing stray: every key belongs to the English set.
            for key in table.keys {
                let base = String(key.split(separator: "#")[0])
                XCTAssertTrue(singular[key] != nil || plurals.contains(base), "\(language): unknown key \(key)")
            }
        }
    }

    func testNoTranslationNamesAnAIProvider() {
        let banned = ["openai", "chatgpt", "gpt", "anthropic", "claude", "gemini", "llama", "qwen", "mistral"]
        for language in SupportStrings.supportedLanguages {
            for (key, text) in SupportStrings.table(language) {
                let lower = text.lowercased()
                XCTAssertFalse(banned.contains { lower.contains($0) }, "\(language): \(key) names a provider")
            }
        }
    }

    // MARK: - Lookup

    func testForcedLanguageReadsItsTableAndFillsPlaceholders() {
        SupportStrings.forcedLanguage = "de"
        XCTAssertEqual(SupportStrings.language, "de")
        XCTAssertEqual(SupportStrings.text("support.home.subtitle"), SupportStrings.table("de")["support.home.subtitle"])
        XCTAssertNotEqual(SupportStrings.text("support.home.subtitle"), "How can we help today?")
        let title = SupportStrings.text("support.home.title", ["app": "Sparkly"])
        XCTAssertTrue(title.contains("Sparkly"))
        XCTAssertFalse(title.contains("{app}"))
        SupportStrings.forcedLanguage = "pt-BR"
        XCTAssertEqual(SupportStrings.language, "pt-BR")
        XCTAssertEqual(SupportStrings.text("support.ai.tag"), SupportStrings.table("pt-BR")["support.ai.tag"])
    }

    func testUnknownLanguageFallsBackToEnglish() {
        XCTAssertEqual(SupportStrings.resolve(appLanguages: [], deviceLanguages: ["xx-YY", "tlh"]), "en")
        SupportStrings.forcedLanguage = "xx"
        XCTAssertEqual(SupportStrings.language, "en")
        XCTAssertEqual(SupportStrings.text("support.home.subtitle"), "How can we help today?")
        XCTAssertEqual(SupportStrings.plural("support.a11y.unread", count: 1), "1 unread message")
        XCTAssertEqual(SupportStrings.plural("support.a11y.unread", count: 3), "3 unread messages")
        // A key the table doesn't have shows the key, never an empty label.
        XCTAssertEqual(SupportStrings.text("support.not.a.key"), "support.not.a.key")
    }

    func testMissingTranslationFallsBackToEnglish() {
        XCTAssertNil(SupportStrings.bundled("support.home.subtitle", language: "xx"))
        XCTAssertEqual(SupportStrings.table("xx"), [:])
        SupportStrings.forcedLanguage = "fr"
        // The lookup chain ends in English for a key only English has.
        XCTAssertEqual(SupportStrings.bundled("support.home.subtitle", language: "en"), "How can we help today?")
    }

    func testOverrideWinsInEveryLanguage() {
        SupportStrings.overrides = [
            "support.home.subtitle": "What's up, {name}?",
            "support.a11y.unread#one": "One new reply",
            "support.thread.sending": "",
        ]
        for language in ["en", "de", "ar", "ja"] {
            SupportStrings.forcedLanguage = language
            XCTAssertEqual(SupportStrings.text("support.home.subtitle", ["name": "Jay"]), "What's up, Jay?")
            // A form override applies where the language uses that form (Japanese has only "other").
            let expected = language == "ja" ? SupportStrings.fill(SupportStrings.table("ja")["support.a11y.unread#other"]!, ["count": "1"]) : "One new reply"
            XCTAssertEqual(SupportStrings.plural("support.a11y.unread", count: 1), expected)
        }
        SupportStrings.forcedLanguage = "en"
        XCTAssertEqual(SupportStrings.plural("support.a11y.unread", count: 2), "2 unread messages", "other forms keep the catalogue")
        XCTAssertEqual(SupportStrings.text("support.thread.sending"), "", "an override may blank a string")
        // A plain key overrides every plural form.
        SupportStrings.overrides = ["support.a11y.unread": "{count} new"]
        XCTAssertEqual(SupportStrings.plural("support.a11y.unread", count: 5), "5 new")
    }

    func testPlaceholdersFillByNameInAnyOrderOnce() {
        XCTAssertEqual(SupportStrings.fill("{time} · {name}", ["name": "Jay", "time": "1h"]), "1h · Jay")
        XCTAssertEqual(SupportStrings.fill("Hi {name} {unknown}", ["name": "Jay"]), "Hi Jay {unknown}")
        XCTAssertEqual(SupportStrings.fill("Hi {name}", ["name": "{time}", "time": "x"]), "Hi {time}", "values are never expanded again")
        XCTAssertEqual(SupportStrings.fill("{ {name}}", ["name": "a"]), "{ a}")
        XCTAssertEqual(SupportStrings.fill("{name", ["name": "a"]), "{name")
    }

    // MARK: - Language choice

    func testTheAppsLanguageWinsSoTheChatMatchesTheApp() {
        // An English-only app on a German phone: the chat stays English like the app.
        XCTAssertEqual(SupportStrings.resolve(appLanguages: ["en"], deviceLanguages: ["de-DE", "en"]), "en")
        // An app running in German.
        XCTAssertEqual(SupportStrings.resolve(appLanguages: ["de"], deviceLanguages: ["de-DE"]), "de")
        // No declared app languages: the device's order.
        XCTAssertEqual(SupportStrings.resolve(appLanguages: [], deviceLanguages: ["fr-CA", "en"]), "fr")
        // An app language the SDK doesn't ship falls through to the device.
        XCTAssertEqual(SupportStrings.resolve(appLanguages: ["fil"], deviceLanguages: ["tl", "it-IT"]), "it")
    }

    func testRegionalVariantsMatchTheRightTable() {
        let cases: [(String, String)] = [
            ("es", "es"), ("es-ES", "es"), ("es-MX", "es-MX"), ("es-419", "es-MX"), ("es-US", "es-MX"), ("es_AR", "es-MX"),
            ("pt", "pt-BR"), ("pt-BR", "pt-BR"), ("pt-PT", "pt-PT"), ("pt-AO", "pt-PT"),
            ("zh-Hans", "zh-Hans"), ("zh-Hans-CN", "zh-Hans"), ("zh", "zh-Hans"), ("zh-CN", "zh-Hans"), ("zh-SG", "zh-Hans"),
            ("zh-Hant", "zh-Hant"), ("zh-Hant-TW", "zh-Hant"), ("zh-TW", "zh-Hant"), ("zh-HK", "zh-Hant"), ("zh-Hant-HK", "zh-Hant"),
            ("nb", "nb"), ("no", "nb"), ("nn-NO", "nb"), ("nb-NO", "nb"),
            ("iw", "he"), ("he-IL", "he"), ("in", "id"), ("ms-MY", "ms"),
            ("en-GB", "en"), ("de-AT", "de"), ("fr-CH", "fr"), ("sr", "en"),
        ]
        for (preference, expected) in cases {
            XCTAssertEqual(SupportStrings.match([preference]) ?? "en", expected, preference)
        }
        for language in SupportStrings.supportedLanguages {
            XCTAssertEqual(SupportStrings.match([language]), language, "every shipped table matches itself")
        }
    }

    func testRightToLeftLanguages() {
        SupportStrings.forcedLanguage = "ar"
        XCTAssertTrue(SupportStrings.isRightToLeft)
        SupportStrings.forcedLanguage = "he"
        XCTAssertTrue(SupportStrings.isRightToLeft)
        SupportStrings.forcedLanguage = "de"
        XCTAssertFalse(SupportStrings.isRightToLeft)
    }

    // MARK: - Plurals

    func testPluralCategoriesFollowCLDR() {
        func check(_ language: String, _ expected: [Int: String]) {
            for (n, category) in expected { XCTAssertEqual(SupportStrings.pluralCategory(n, language: language), category, "\(language) \(n)") }
        }
        check("en", [0: "other", 1: "one", 2: "other"])
        check("ja", [0: "other", 1: "other", 5: "other"])
        check("fr", [0: "one", 1: "one", 2: "other", 1_000_000: "many"])
        check("pt-BR", [0: "one", 1: "one", 2: "other"])
        check("pt-PT", [0: "other", 1: "one", 2: "other", 1_000_000: "many"])
        check("es-MX", [0: "other", 1: "one", 1_000_000: "many"])
        check("hi", [0: "one", 1: "one", 2: "other"])
        check("ru", [1: "one", 2: "few", 4: "few", 5: "many", 11: "many", 12: "many", 21: "one", 22: "few", 25: "many", 111: "many"])
        check("uk", [1: "one", 3: "few", 0: "many"])
        check("pl", [1: "one", 2: "few", 5: "many", 21: "many", 22: "few", 0: "many"])
        check("cs", [1: "one", 2: "few", 4: "few", 5: "other", 0: "other"])
        check("sk", [1: "one", 3: "few", 22: "other"])
        check("hr", [1: "one", 21: "one", 11: "other", 2: "few", 24: "few", 5: "other"])
        check("ro", [0: "few", 1: "one", 2: "few", 19: "few", 20: "other", 101: "few", 120: "other"])
        check("ar", [0: "zero", 1: "one", 2: "two", 3: "few", 10: "few", 11: "many", 99: "many", 100: "other", 103: "few"])
        check("he", [1: "one", 2: "two", 3: "other", 20: "other"])
    }

    func testPluralUsesTheLanguagesForm() {
        SupportStrings.forcedLanguage = "ru"
        let table = SupportStrings.table("ru")
        XCTAssertEqual(SupportStrings.plural("support.a11y.unread", count: 1), SupportStrings.fill(table["support.a11y.unread#one"]!, ["count": "1"]))
        XCTAssertEqual(SupportStrings.plural("support.a11y.unread", count: 3), SupportStrings.fill(table["support.a11y.unread#few"]!, ["count": "3"]))
        XCTAssertEqual(SupportStrings.plural("support.a11y.unread", count: 7), SupportStrings.fill(table["support.a11y.unread#many"]!, ["count": "7"]))
    }

    // MARK: - Errors

    func testErrorsShowLocalizedTextNotServerMessages() {
        SupportStrings.forcedLanguage = "en"
        XCTAssertEqual(SupportStrings.errorText(AppReferSupportError(status: 429, message: "rate_limited")), SupportStrings.text("support.error.rateLimited"))
        XCTAssertEqual(SupportStrings.errorText(AppReferSupportError(status: 413, message: "too_large")), SupportStrings.text("support.error.tooLong"))
        XCTAssertEqual(SupportStrings.errorText(AppReferSupportError(status: 500, message: "boom")), SupportStrings.text("support.error.generic"))
        XCTAssertEqual(SupportStrings.errorText(SupportAPI.storeUnavailable()), SupportStrings.text("support.error.locked"))
        XCTAssertEqual(SupportStrings.errorText(AppReferSupportError(status: 502, message: "x", reason: .upload)), SupportStrings.text("support.error.upload"))
        XCTAssertEqual(SupportStrings.errorText(URLError(.notConnectedToInternet)), SupportStrings.text("support.error.offline"))
        XCTAssertEqual(SupportStrings.errorText(CocoaError(.fileNoSuchFile)), SupportStrings.text("support.error.generic"))
        SupportStrings.forcedLanguage = "de"
        XCTAssertEqual(SupportStrings.errorText(URLError(.timedOut)), SupportStrings.table("de")["support.error.offline"])
        // The raw message stays available for logs.
        XCTAssertEqual(AppReferSupportError(status: 429, message: "rate_limited").errorDescription, "rate_limited")
    }
}
