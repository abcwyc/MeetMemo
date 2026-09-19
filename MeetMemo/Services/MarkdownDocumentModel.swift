import Foundation

/// Structural, line-addressable model of a Markdown document.
///
/// This is the shared parsing layer behind the meeting-notes markdown UI. It is
/// deliberately platform-neutral (no SwiftUI/AppKit) so it can back:
/// - the live-preview editor's syntax show/hide (block + inline ranges)
/// - block-level click-to-edit write-back (line ranges)
/// - eventually `MeetingHTMLExporter`'s markdown→HTML pass, replacing the
///   separate ad-hoc implementation there.
///
/// It is not a full CommonMark implementation — it matches the subset already
/// produced by `NotesGenerator`'s prompts and previously hand-rolled in
/// `RenderedNotesView`: headings, (nested) lists with optional task
/// checkboxes, blockquotes, fenced code blocks, thematic breaks, GFM-style
/// pipe tables, and paragraphs, with inline bold/italic/strikethrough/code/link.
enum MarkdownDocumentModel {

    // MARK: - Block model

    struct Table: Equatable {
        let headers: [String]
        let rows: [[String]]
        let columnCount: Int
    }

    enum BlockKind: Equatable {
        case heading(level: Int)
        case paragraph
        case listItem(ordered: Bool, indentLevel: Int, marker: String, checkbox: Bool?)
        case blockquote
        case codeBlock(language: String?)
        case table(Table)
        case thematicBreak
        case blank
    }

    /// A single block-level element.
    struct Block: Equatable {
        let kind: BlockKind
        /// 0-based, inclusive line range in the source document this block spans.
        let lineRange: ClosedRange<Int>
        /// The block's raw source text (its lines, joined with "\n"), verbatim.
        /// Used for round-trip block-level editing: replacing `lineRange` in the
        /// source with an edited version of `rawText` preserves everything the
        /// parser didn't model.
        let rawText: String
        /// Inline-parsed content for blocks that render inline spans (heading,
        /// paragraph, listItem, blockquote). `nil` for codeBlock/table/
        /// thematicBreak/blank, which either have no inline content or (table)
        /// carry per-cell content instead.
        let content: InlineContent?
    }

    // MARK: - Inline model

    struct InlineSpan: Equatable {
        enum Kind: Equatable {
            case bold
            case italic
            case strikethrough
            case inlineCode
            case link(destination: String)
        }

        let kind: Kind
        /// Full range within the containing content string, including markers.
        let range: NSRange
        /// The opening marker/delimiter range (e.g. "**", "[").
        let openingMarkerRange: NSRange
        /// The closing marker/delimiter range (e.g. "**", "](url)").
        let closingMarkerRange: NSRange
        /// The human-visible text between the markers.
        let contentRange: NSRange
    }

    struct InlineContent: Equatable {
        /// Text with block-level prefixes already stripped (e.g. "## ", "- ",
        /// "> "), i.e. what a renderer shows for this block/list-item/quote line.
        let text: String
        let spans: [InlineSpan]
    }

    // MARK: - Parsing entry point

    static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var index = 0

        while index < lines.count {
            if let (table, nextIndex) = parseTable(startingAt: index, in: lines) {
                blocks.append(
                    Block(
                        kind: .table(table),
                        lineRange: index...(nextIndex - 1),
                        rawText: lines[index..<nextIndex].joined(separator: "\n"),
                        content: nil
                    )
                )
                index = nextIndex
                continue
            }

            if let (language, nextIndex) = parseCodeFenceStart(lines[index]) {
                let endIndex = findCodeFenceEnd(startingAt: index + 1, in: lines) ?? lines.count
                blocks.append(
                    Block(
                        kind: .codeBlock(language: language),
                        lineRange: index...(endIndex == lines.count ? lines.count - 1 : endIndex),
                        rawText: lines[index...(min(endIndex, lines.count - 1))].joined(separator: "\n"),
                        content: nil
                    )
                )
                _ = nextIndex // fence-open line itself carries no further info
                index = endIndex < lines.count ? endIndex + 1 : lines.count
                continue
            }

            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                blocks.append(
                    Block(kind: .blank, lineRange: index...index, rawText: lines[index], content: nil)
                )
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                blocks.append(
                    Block(kind: .thematicBreak, lineRange: index...index, rawText: lines[index], content: nil)
                )
                index += 1
                continue
            }

            if let level = headingLevel(for: trimmed) {
                let stripped = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                blocks.append(
                    Block(
                        kind: .heading(level: level),
                        lineRange: index...index,
                        rawText: lines[index],
                        content: InlineContent(text: stripped, spans: parseInlineSpans(in: stripped))
                    )
                )
                index += 1
                continue
            }

            if let (indentLevel, marker, ordered, checkbox, content) = listItemInfo(for: lines[index]) {
                blocks.append(
                    Block(
                        kind: .listItem(ordered: ordered, indentLevel: indentLevel, marker: marker, checkbox: checkbox),
                        lineRange: index...index,
                        rawText: lines[index],
                        content: InlineContent(text: content, spans: parseInlineSpans(in: content))
                    )
                )
                index += 1
                continue
            }

            if let quoteContent = blockquoteContent(for: trimmed) {
                let startIndex = index
                var quoteLines = [quoteContent]
                var nextIndex = index + 1
                while nextIndex < lines.count,
                      let nested = blockquoteContent(for: lines[nextIndex].trimmingCharacters(in: .whitespaces)) {
                    quoteLines.append(nested)
                    nextIndex += 1
                }
                let joined = quoteLines.joined(separator: "\n")
                blocks.append(
                    Block(
                        kind: .blockquote,
                        lineRange: startIndex...(nextIndex - 1),
                        rawText: lines[startIndex..<nextIndex].joined(separator: "\n"),
                        content: InlineContent(text: joined, spans: parseInlineSpans(in: joined))
                    )
                )
                index = nextIndex
                continue
            }

            // Paragraph: merge this line with any immediately following plain
            // lines (not blank/heading/list/quote/table/fence/rule).
            let startIndex = index
            var paragraphLines = [lines[index]]
            var nextIndex = index + 1
            while nextIndex < lines.count, isParagraphContinuation(lines[nextIndex]) {
                paragraphLines.append(lines[nextIndex])
                nextIndex += 1
            }
            let joined = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(
                Block(
                    kind: .paragraph,
                    lineRange: startIndex...(nextIndex - 1),
                    rawText: lines[startIndex..<nextIndex].joined(separator: "\n"),
                    content: InlineContent(text: joined, spans: parseInlineSpans(in: joined))
                )
            )
            index = nextIndex
        }

        return blocks
    }

    // MARK: - Block-level helpers

    private static func isParagraphContinuation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if isThematicBreak(trimmed) { return false }
        if headingLevel(for: trimmed) != nil { return false }
        if listItemInfo(for: line) != nil { return false }
        if blockquoteContent(for: trimmed) != nil { return false }
        if parseCodeFenceStart(line) != nil { return false }
        if isTableRow(line) { return false }
        return true
    }

    private static func headingLevel(for line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var count = 0
        for char in line {
            if char == "#" {
                count += 1
            } else if char == " " {
                return min(count, 6)
            } else {
                return nil
            }
        }
        return nil
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func blockquoteContent(for trimmed: String) -> String? {
        guard trimmed.hasPrefix(">") else { return nil }
        var rest = String(trimmed.dropFirst())
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return rest
    }

    private static func parseCodeFenceStart(_ line: String) -> (language: String?, nextIndex: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let fenceChar = trimmed.first!
        let markerLength = trimmed.prefix(while: { $0 == fenceChar }).count
        guard markerLength >= 3 else { return nil }
        let languageRaw = String(trimmed.dropFirst(markerLength)).trimmingCharacters(in: .whitespaces)
        return (languageRaw.isEmpty ? nil : languageRaw, 0)
    }

    private static func findCodeFenceEnd(startingAt index: Int, in lines: [String]) -> Int? {
        var i = index
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func listItemInfo(
        for line: String
    ) -> (indentLevel: Int, marker: String, ordered: Bool, checkbox: Bool?, content: String)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indentLevel = leadingSpaces / 4
        var remaining = String(line.dropFirst(leadingSpaces))

        let marker: String
        let ordered: Bool
        if remaining.hasPrefix("- ") {
            marker = "-"
            ordered = false
            remaining = String(remaining.dropFirst(2))
        } else if remaining.hasPrefix("* ") {
            marker = "*"
            ordered = false
            remaining = String(remaining.dropFirst(2))
        } else if let dotIndex = remaining.firstIndex(of: "."),
                  let num = Int(remaining[remaining.startIndex..<dotIndex]),
                  remaining[dotIndex..<remaining.endIndex].hasPrefix(". ") {
            marker = "\(num)."
            ordered = true
            remaining = String(remaining[remaining.index(dotIndex, offsetBy: 2)...])
        } else {
            return nil
        }

        var checkbox: Bool?
        if remaining.hasPrefix("[ ] ") {
            checkbox = false
            remaining = String(remaining.dropFirst(4))
        } else if remaining.hasPrefix("[ ]"), remaining.count == 3 {
            checkbox = false
            remaining = ""
        } else if remaining.lowercased().hasPrefix("[x] ") {
            checkbox = true
            remaining = String(remaining.dropFirst(4))
        } else if remaining.lowercased().hasPrefix("[x]"), remaining.count == 3 {
            checkbox = true
            remaining = ""
        }

        return (indentLevel, marker, ordered, checkbox, remaining.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Table parsing

    private static func parseTable(startingAt index: Int, in lines: [String]) -> (value: Table, nextIndex: Int)? {
        guard index + 1 < lines.count,
              isTableRow(lines[index]),
              isSeparatorRow(lines[index + 1]) else {
            return nil
        }

        var rows = [parseCells(lines[index])]
        var nextIndex = index + 2

        while nextIndex < lines.count, isTableRow(lines[nextIndex]), !isSeparatorRow(lines[nextIndex]) {
            rows.append(parseCells(lines[nextIndex]))
            nextIndex += 1
        }

        guard let headers = rows.first, !headers.isEmpty else { return nil }
        let columnCount = rows.map(\.count).max() ?? headers.count
        return (
            Table(headers: headers, rows: Array(rows.dropFirst()), columnCount: columnCount),
            nextIndex
        )
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && parseCells(line).count >= 2
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let cells = parseCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return false }
            return trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseCells(_ line: String) -> [String] {
        var normalized = line.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("|") {
            normalized.removeFirst()
        }
        if normalized.hasSuffix("|") {
            normalized.removeLast()
        }

        return normalized
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Inline parsing

    /// Parses bold/italic/strikethrough/inline-code/link spans in `text`.
    /// Non-overlapping, left-to-right, highest-precedence-first: inline code
    /// spans are found first and their interiors excluded from further
    /// matching (matching CommonMark's "code spans bind tighter" rule), then
    /// links, then bold, then italic, then strikethrough.
    ///
    /// Called on every keystroke by the live-preview editor's restyle pass,
    /// so this is a hot path: `NSRegularExpression` compilation (not just
    /// matching) is expensive enough to be noticeable per-line, per-edit —
    /// `cachedRegex` compiles each of the fixed pattern strings below once
    /// and reuses it for the process's lifetime.
    private static nonisolated(unsafe) var regexCache: [String: NSRegularExpression] = [:]

    /// `static let` is initialized exactly once, thread-safely, by the Swift runtime.
    private static let regexCacheLock = NSLock()

    /// `regexCache` is read from the editor's restyle pass (main) and from
    /// export/preview paths off the main actor; the lock serializes
    /// read-modify-write. Held across the one-time compile on purpose so two
    /// threads can never both compile (and store) the same pattern.
    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = regex
        return regex
    }

    static func parseInlineSpans(in text: String) -> [InlineSpan] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var claimed = [Bool](repeating: false, count: ns.length)
        var spans: [InlineSpan] = []

        func isFree(_ range: NSRange) -> Bool {
            guard range.location >= 0, range.location + range.length <= claimed.count else { return false }
            for i in range.location..<(range.location + range.length) where claimed[i] { return false }
            return true
        }

        func claim(_ range: NSRange) {
            for i in range.location..<(range.location + range.length) { claimed[i] = true }
        }

        func scan(pattern: String, makeSpan: (NSTextCheckingResult) -> InlineSpan?) {
            guard let regex = cachedRegex(pattern) else { return }
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                guard isFree(match.range) else { continue }
                guard let span = makeSpan(match) else { continue }
                claim(span.range)
                spans.append(span)
            }
        }

        // 1) Inline code: `code` — no escaping of nested markers inside.
        scan(pattern: "`([^`]+)`") { match in
            guard let contentRange = Optional(match.range(at: 1)), contentRange.location != NSNotFound else { return nil }
            let openRange = NSRange(location: match.range.location, length: 1)
            let closeRange = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            return InlineSpan(kind: .inlineCode, range: match.range, openingMarkerRange: openRange, closingMarkerRange: closeRange, contentRange: contentRange)
        }

        // 2) Links: [text](url)
        scan(pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)") { match in
            let contentRange = match.range(at: 1)
            let destRange = match.range(at: 2)
            guard contentRange.location != NSNotFound, destRange.location != NSNotFound else { return nil }
            let destination = ns.substring(with: destRange)
            let openRange = NSRange(location: match.range.location, length: 1)
            let closeStart = contentRange.location + contentRange.length
            let closeRange = NSRange(location: closeStart, length: match.range.location + match.range.length - closeStart)
            return InlineSpan(kind: .link(destination: destination), range: match.range, openingMarkerRange: openRange, closingMarkerRange: closeRange, contentRange: contentRange)
        }

        // 3) Bold: **text** or __text__
        scan(pattern: "\\*\\*([^\\*]+)\\*\\*") { match in
            InlineDelimitedSpanFactory.make(.bold, match: match, in: ns, markerLength: 2)
        }
        scan(pattern: "__([^_]+)__") { match in
            InlineDelimitedSpanFactory.make(.bold, match: match, in: ns, markerLength: 2)
        }

        // 4) Strikethrough: ~~text~~
        scan(pattern: "~~([^~]+)~~") { match in
            InlineDelimitedSpanFactory.make(.strikethrough, match: match, in: ns, markerLength: 2)
        }

        // 5) Italic: *text* or _text_ (single, not doubled — bold already claimed those ranges)
        scan(pattern: "(?<!\\*)\\*([^\\*]+)\\*(?!\\*)") { match in
            InlineDelimitedSpanFactory.make(.italic, match: match, in: ns, markerLength: 1)
        }
        scan(pattern: "(?<!_)_([^_]+)_(?!_)") { match in
            InlineDelimitedSpanFactory.make(.italic, match: match, in: ns, markerLength: 1)
        }

        return spans.sorted { $0.range.location < $1.range.location }
    }
}

private enum InlineDelimitedSpanFactory {
    static func make(
        _ kind: MarkdownDocumentModel.InlineSpan.Kind,
        match: NSTextCheckingResult,
        in ns: NSString,
        markerLength: Int
    ) -> MarkdownDocumentModel.InlineSpan? {
        let contentRange = match.range(at: 1)
        guard contentRange.location != NSNotFound else { return nil }
        let openRange = NSRange(location: match.range.location, length: markerLength)
        let closeRange = NSRange(location: match.range.location + match.range.length - markerLength, length: markerLength)
        return MarkdownDocumentModel.InlineSpan(
            kind: kind,
            range: match.range,
            openingMarkerRange: openRange,
            closingMarkerRange: closeRange,
            contentRange: contentRange
        )
    }
}
