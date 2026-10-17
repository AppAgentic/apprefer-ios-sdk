import Foundation

/// A block of a help article.
enum SupportMarkdownBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    /// One list item; `depth` 0 is the outer list. `number` is set for ordered lists.
    case listItem(number: Int?, depth: Int, text: AttributedString)
    case quote(AttributedString)
    case code(String)
    case rule
    /// A picture on its own line (http/https only).
    case image(url: URL, alt: String)
}

/// A small, safe markdown reader for help articles. Block structure (headings, lists,
/// quotes, fenced code, rules, images) is parsed here; inline styling (bold, italic, code,
/// strikethrough, links) uses Foundation's `AttributedString(markdown:)`. Nothing is ever
/// executed: HTML tags are dropped (script and style with their content), and links keep
/// only http(s) and mailto targets, everything else (javascript:, data:, file:, relative
/// paths, app schemes) becomes plain text.
enum SupportMarkdown {
    static func blocks(_ markdown: String) -> [SupportMarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [SupportMarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var listOpen = false
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(joinLines(paragraph))))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(inline(joinLines(quote))))
            quote = []
        }
        func flushAll() { flushParagraph(); flushQuote(); listOpen = false }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            // Fenced code: everything up to the closing fence, as written.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                index += 1 // the closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty { flushAll(); continue }

            // Setext headings: a paragraph line underlined with === or ---.
            if !paragraph.isEmpty, trimmed.count >= 2, trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                let text = joinLines(paragraph); paragraph = []
                blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, text: inline(text)))
                continue
            }
            if isRule(trimmed) { flushAll(); blocks.append(.rule); continue }

            if let heading = atxHeading(trimmed) {
                flushAll()
                blocks.append(.heading(level: heading.level, text: inline(heading.text)))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); listOpen = false
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if let item = listItem(line) {
                flushParagraph()
                listOpen = true
                blocks.append(.listItem(number: item.number, depth: item.depth, text: inline(item.text)))
                continue
            }
            // An indented line right after a list item continues that item.
            if listOpen, line.first == " " || line.first == "\t", case let .listItem(number, depth, text)? = blocks.last {
                var joined = text
                joined.append(AttributedString(" "))
                joined.append(inline(trimmed))
                blocks[blocks.count - 1] = .listItem(number: number, depth: depth, text: joined)
                continue
            }
            listOpen = false
            if paragraph.isEmpty, let image = standaloneImage(trimmed) {
                if case let .paragraph(alt) = image, alt.characters.isEmpty { continue }
                blocks.append(image)
                continue
            }
            paragraph.append(line)
        }
        flushAll()
        return blocks
    }

    // MARK: Inline

    /// Inline markdown with only safe links kept and HTML tags removed.
    static func inline(_ text: String) -> AttributedString {
        let cleaned = stripHTML(text)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var result = (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
        for run in result.runs {
            if let link = run.link, safeURL(link.absoluteString) == nil {
                result[run.range].link = nil
            }
            if run.imageURL != nil { result[run.range].imageURL = nil }
        }
        return result
    }

    /// The URL when it is an http(s) link with a host, or a mailto link; nil otherwise.
    static func safeURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return (url.host?.isEmpty == false) ? url : nil
        case "mailto": return trimmed.count > "mailto:".count ? url : nil
        default: return nil
        }
    }

    /// Removes HTML tags (and script/style elements with their content) outside `code` spans.
    /// Autolinks such as `<https://…>` and `<a@b.com>` are kept.
    static func stripHTML(_ text: String) -> String {
        guard text.contains("<") else { return text }
        let parts = text.components(separatedBy: "`")
        return parts.enumerated().map { i, part in
            guard i % 2 == 0, part.contains("<") else { return part }
            var s = part.replacingOccurrences(of: "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<(script|style)\\b[^>]*>[\\s\\S]*$", with: "", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "</?[A-Za-z][A-Za-z0-9-]*(\\s[^<>]*)?/?>", with: "", options: .regularExpression)
            return s
        }.joined(separator: "`")
    }

    // MARK: Block helpers

    /// Lines of one paragraph: a soft break is a space; two trailing spaces or a backslash
    /// make a line break.
    private static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for (i, raw) in lines.enumerated() {
            let hard = raw.hasSuffix("  ") || raw.hasSuffix("\\")
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\\") { line.removeLast() }
            out += line
            if i < lines.count - 1 { out += hard ? "\n" : " " }
        }
        return out
    }

    private static func isRule(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func atxHeading(_ s: String) -> (level: Int, text: String)? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes ("## Title ##").
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (number: Int?, depth: Int, text: String)? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(indent)
        let depth = min(indent / 2, 3)
        if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // "- [ ] task" / "- [x] task": shown as a plain item with a box.
            if text.hasPrefix("[ ] ") { return (nil, depth, "☐ " + text.dropFirst(4)) }
            if text.lowercased().hasPrefix("[x] ") { return (nil, depth, "☑︎ " + text.dropFirst(4)) }
            return (nil, depth, text)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else { return nil }
        return (Int(digits), depth, after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// `![alt](url "title")` alone on a line.
    private static func standaloneImage(_ s: String) -> SupportMarkdownBlock? {
        guard s.hasPrefix("!["), s.hasSuffix(")"), let close = s.range(of: "](") else { return nil }
        let alt = String(s[s.index(s.startIndex, offsetBy: 2)..<close.lowerBound])
        var target = String(s[close.upperBound..<s.index(before: s.endIndex)]).trimmingCharacters(in: .whitespaces)
        if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
        target = target.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard let url = safeURL(target), url.scheme?.lowercased() != "mailto" else { return .paragraph(AttributedString(alt)) }
        return .image(url: url, alt: alt)
    }
}
