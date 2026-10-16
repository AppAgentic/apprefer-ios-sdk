import Foundation

/// The help chat's text, in 35 languages.
///
/// Lookup order for every key: the app's override (`AppRefer.support.strings`), then the
/// bundled table for the chat's language, then English. The chat's language follows the
/// host app: the language the app is running in (`Bundle.main.preferredLocalizations`),
/// so an app that ships fewer languages than the SDK gets a chat that matches its own
/// screens; then the device's preferred languages; then English.
/// `AppRefer.support.language` forces one.
///
/// Keys and translations come from the shared table every AppRefer SDK uses
/// (`Localization/support-strings.json` in this repo). `{name}`-style placeholders are
/// filled in by name, so a translation may reorder them. Plural keys are stored as
/// `key#one`, `key#few`, … (CLDR cardinal categories) and picked with `pluralCategory`.
enum SupportStrings {
    /// Every language the SDK ships, as `.lproj` names.
    static let supportedLanguages = [
        "ar", "ca", "cs", "da", "de", "el", "en", "es", "es-MX", "fi", "fr", "he", "hi", "hr", "hu", "id", "it", "ja",
        "ko", "ms", "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var overrides: [String: String] = [:]
        var forcedLanguage: String?
        var resolved: String?
        var tables: [String: [String: String]] = [:]
    }
    private static let state = State()

    // MARK: - Configuration (AppRefer.support.strings / .language)

    static var overrides: [String: String] {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.overrides }
        set { state.lock.lock(); state.overrides = newValue; state.lock.unlock() }
    }

    static var forcedLanguage: String? {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.forcedLanguage }
        set { state.lock.lock(); state.forcedLanguage = newValue; state.resolved = nil; state.lock.unlock() }
    }

    // MARK: - Language

    /// The chat's language (an `.lproj` name such as "de", "pt-BR" or "zh-Hant").
    static var language: String {
        state.lock.lock()
        if let resolved = state.resolved { state.lock.unlock(); return resolved }
        let forced = state.forcedLanguage
        state.lock.unlock()
        let value: String
        if let forced {
            value = match([forced]) ?? "en"
        } else {
            let declared = Bundle.main.localizations.filter { $0 != "Base" }
            let appLanguages = declared.isEmpty ? [] : Bundle.main.preferredLocalizations.filter { $0 != "Base" }
            value = resolve(appLanguages: appLanguages, deviceLanguages: Locale.preferredLanguages)
        }
        state.lock.lock()
        if state.forcedLanguage == forced { state.resolved = value }
        state.lock.unlock()
        return value
    }

    /// The language the app runs in comes first, so the chat matches the app's screens;
    /// then the device's languages; then English.
    static func resolve(appLanguages: [String], deviceLanguages: [String]) -> String {
        match(appLanguages + deviceLanguages) ?? "en"
    }

    /// The first preference the SDK has a table for. Regional variants map to the table a
    /// speaker expects: Latin American Spanish to es-MX, Portuguese outside Brazil to pt-PT,
    /// Chinese by script (Taiwan, Hong Kong and Macau to Traditional), Norwegian to Bokmål.
    static func match(_ preferences: [String]) -> String? {
        for preference in preferences {
            let parts = preference.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let first = parts.first?.lowercased(), !first.isEmpty else { continue }
            let rest = parts.dropFirst()
            let script = rest.first { $0.count == 4 }?.capitalized
            let region = rest.first { $0.count == 2 || ($0.count == 3 && Int($0) != nil) }?.uppercased()
            switch first {
            case "zh":
                let traditional = script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? ""))
                return traditional ? "zh-Hant" : "zh-Hans"
            case "pt":
                return region == nil || region == "BR" ? "pt-BR" : "pt-PT"
            case "es":
                return region.map { Self.spanishEurope.contains($0) } ?? true ? "es" : "es-MX"
            case "nb", "no", "nn": return "nb"
            case "iw": return "he"
            case "in": return "id"
            default:
                if supportedLanguages.contains(first) { return first }
            }
        }
        return nil
    }

    /// Regions that read Spain's Spanish; every other region (Latin America, the US, "419") gets es-MX.
    private static let spanishEurope: Set<String> = ["ES", "GQ", "EA", "IC", "AD"]

    static var locale: Locale { Locale(identifier: language) }

    static var isRightToLeft: Bool { ["ar", "he"].contains(language) }

    // MARK: - Lookup

    /// The text for `key` with `{placeholders}` filled in.
    static func text(_ key: String, _ arguments: [String: String] = [:]) -> String {
        let template = overrides[key] ?? bundled(key, language: language) ?? bundled(key, language: "en") ?? key
        return fill(template, arguments)
    }

    /// A plural key: the form for `count` in the chat's language, with `{count}` filled in.
    static func plural(_ key: String, count: Int, _ arguments: [String: String] = [:]) -> String {
        let lang = language
        let category = pluralCategory(count, language: lang)
        let custom = overrides
        var arguments = arguments
        arguments["count"] = NumberFormatter.localizedString(from: NSNumber(value: count), number: .none)
        let template = custom["\(key)#\(category)"] ?? custom[key]
            ?? bundled("\(key)#\(category)", language: lang) ?? bundled("\(key)#other", language: lang)
            ?? bundled("\(key)#\(pluralCategory(count, language: "en"))", language: "en") ?? key
        return fill(template, arguments)
    }

    /// The bundled translation, or nil when the language or key is missing.
    static func bundled(_ key: String, language: String) -> String? {
        table(language)[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One language's whole table (cached).
    static func table(_ language: String) -> [String: String] {
        state.lock.lock()
        if let cached = state.tables[language] { state.lock.unlock(); return cached }
        state.lock.unlock()
        var loaded: [String: String] = [:]
        if let url = Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language)
            ?? Bundle.module.path(forResource: language, ofType: "lproj").map({ URL(fileURLWithPath: $0).appendingPathComponent("Localizable.strings") }),
           let dictionary = NSDictionary(contentsOf: url) as? [String: String] {
            loaded = dictionary
        }
        state.lock.lock()
        state.tables[language] = loaded
        state.lock.unlock()
        return loaded
    }

    /// Replaces `{name}` with `arguments["name"]`; unknown placeholders stay as written.
    /// One pass, so a value that itself contains braces is never expanded again.
    static func fill(_ template: String, _ arguments: [String: String]) -> String {
        guard !arguments.isEmpty, template.contains("{") else { return template }
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let after = rest.index(after: open)
            if let close = rest[after...].firstIndex(of: "}"), let value = arguments[String(rest[after..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[after...]
            }
        }
        return result + rest
    }

    // MARK: - Plurals

    /// The CLDR cardinal plural category of a whole number in one of the SDK's languages.
    static func pluralCategory(_ count: Int, language: String) -> String {
        let n = abs(count)
        let n10 = n % 10, n100 = n % 100
        switch language.split(separator: "-").first.map(String.init) ?? language {
        case "ja", "ko", "zh", "th", "vi", "id", "ms":
            return "other"
        case "hi":
            return n <= 1 ? "one" : "other"
        case "fr", "pt" where language != "pt-PT":
            if n <= 1 { return "one" }
            return n % 1_000_000 == 0 ? "many" : "other"
        case "pt", "es", "it", "ca":
            if n == 1 { return "one" }
            return n != 0 && n % 1_000_000 == 0 ? "many" : "other"
        case "ru", "uk":
            if n10 == 1 && n100 != 11 { return "one" }
            if (2...4).contains(n10) && !(12...14).contains(n100) { return "few" }
            return "many"
        case "pl":
            if n == 1 { return "one" }
            if (2...4).contains(n10) && !(12...14).contains(n100) { return "few" }
            return "many"
        case "cs", "sk":
            if n == 1 { return "one" }
            return (2...4).contains(n) ? "few" : "other"
        case "hr":
            if n10 == 1 && n100 != 11 { return "one" }
            if (2...4).contains(n10) && !(12...14).contains(n100) { return "few" }
            return "other"
        case "ro":
            if n == 1 { return "one" }
            return n == 0 || (1...19).contains(n100) ? "few" : "other"
        case "ar":
            switch n {
            case 0: return "zero"
            case 1: return "one"
            case 2: return "two"
            default:
                if (3...10).contains(n100) { return "few" }
                if (11...99).contains(n100) { return "many" }
                return "other"
            }
        case "he":
            if n == 1 { return "one" }
            return n == 2 ? "two" : "other"
        default: // en, de, nl, sv, da, nb, fi, el, hu, tr
            return n == 1 ? "one" : "other"
        }
    }
}

extension SupportStrings {
    /// What to show for a failed request: the customer's language, never a raw server message.
    static func errorText(_ error: Error) -> String {
        if let error = error as? AppReferSupportError {
            switch error.reason {
            case .locked: return text("support.error.locked")
            case .upload: return text("support.error.upload")
            case .unavailable: return text("support.error.unavailable")
            case .server:
                switch error.status {
                case 413: return text("support.error.tooLong")
                case 429: return text("support.error.rateLimited")
                default: return text("support.error.generic")
                }
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return text("support.error.offline")
            default: break
            }
        }
        return text("support.error.generic")
    }
}
