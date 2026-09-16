import AppKit

/// Attribute keys the live-preview markdown editor uses to mark which
/// character ranges are markdown "syntax" (delimiters/prefixes) that should
/// collapse to zero width unless the caret is on their line or inside their
/// inline span. Consumed by `MarkdownLiveLayoutManager`.
enum MarkdownEditorAttribute {
    /// Present (value `true`) on any syntax character range, hidden or not.
    static let syntax = NSAttributedString.Key("MeetMemoMarkdownSyntax")
    /// Present (value `true`) on a *line-level* command range (heading "# ",
    /// blockquote "> "): visible while the caret is anywhere on that line.
    static let lineCommand = NSAttributedString.Key("MeetMemoMarkdownLineCommand")
    /// Present (`NSValue`-wrapped `NSRange`) on an *inline* command's
    /// delimiter ranges ("**", "`", "[", "](url)"): visible while the caret
    /// intersects (or sits just after) the wrapped full-span range.
    static let commandSpan = NSAttributedString.Key("MeetMemoMarkdownCommandSpan")
}

/// Pure decision logic for whether a tagged markdown-syntax range should be
/// visible, given the current caret/selection. Kept separate from
/// `MarkdownLiveLayoutManager`'s glyph substitution so it's unit-testable
/// without any NSTextView/NSLayoutManager.
enum MarkdownLiveVisibility {
    /// A line-level command (e.g. a heading's "# ") is visible while
    /// `charIndex` falls inside the caret's own line range.
    static func isLineCommandVisible(charIndex: Int, caretLineRange: NSRange) -> Bool {
        NSLocationInRange(charIndex, caretLineRange)
    }

    /// An inline command's delimiters are visible while the caret intersects
    /// the command's full span, sits inside it (empty selection), or sits
    /// immediately after its closing delimiter.
    static func spanIsActive(_ span: NSRange, caret: NSRange) -> Bool {
        if NSIntersectionRange(span, caret).length > 0 { return true }
        guard caret.length == 0 else { return false }
        if NSLocationInRange(caret.location, span) { return true }
        return caret.location == NSMaxRange(span)
    }
}

/// Builds a fully-styled, verbatim `NSAttributedString` for a markdown
/// source string: the characters are never altered, only attributes are
/// layered on — headings/emphasis/code/links get their visual styling, and
/// their syntax markers are tagged per `MarkdownEditorAttribute` so
/// `MarkdownLiveLayoutManager` can hide them until the caret is on/inside
/// them (Obsidian/Typora-style live preview).
///
/// Scope for this phase: headings, list markers (always shown, not
/// collapsible), single-line blockquote collapse (subsequent lines of a
/// multi-line quote keep their "> " visible — a follow-up refinement),
/// fenced code blocks (monospace + background, fences not yet collapsible),
/// and inline bold/italic/strikethrough/inline-code/link. Tables and
/// thematic breaks are left as plain text in this phase (see the table
/// attachment-view plan).
enum MarkdownLiveStyler {
    struct Configuration {
        var baseFont: NSFont
        var baseColor: NSColor
        var syntaxColor: NSColor
        var codeFont: NSFont
        var codeBackground: NSColor
        var quoteColor: NSColor
        var linkColor: NSColor

        static func standard(baseFontSize: CGFloat = NSFont.systemFontSize) -> Configuration {
            Configuration(
                baseFont: .systemFont(ofSize: baseFontSize),
                baseColor: .labelColor,
                syntaxColor: .tertiaryLabelColor,
                codeFont: .monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular),
                codeBackground: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
                quoteColor: .secondaryLabelColor,
                linkColor: .linkColor
            )
        }
    }

    static func attributedString(for text: String, configuration: Configuration = .standard()) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: configuration.baseFont, .foregroundColor: configuration.baseColor]
        )
        guard !text.isEmpty else { return result }

        let lines = text.components(separatedBy: .newlines)
        let lineOffsets = lineStartOffsets(for: lines)
        let blocks = MarkdownDocumentModel.parse(text)

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                styleHeading(level: level, block: block, lines: lines, lineOffsets: lineOffsets, into: result, configuration: configuration)
            case .paragraph:
                styleParagraph(block: block, lines: lines, lineOffsets: lineOffsets, into: result, configuration: configuration)
            case .listItem:
                styleListItem(block: block, lines: lines, lineOffsets: lineOffsets, into: result, configuration: configuration)
            case .blockquote:
                styleBlockquote(block: block, lines: lines, lineOffsets: lineOffsets, into: result, configuration: configuration)
            case .codeBlock:
                styleCodeBlock(block: block, lineOffsets: lineOffsets, into: result, configuration: configuration)
            case .table, .thematicBreak, .blank:
                break
            }
        }

        return result
    }

    // MARK: - Line offset table

    private static func lineStartOffsets(for lines: [String]) -> [Int] {
        var offsets = [Int]()
        offsets.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += line.utf16.count + 1 // + 1 for the newline joining this line to the next
        }
        return offsets
    }

    // MARK: - Block styling

    private static func styleHeading(
        level: Int, block: Block, lines: [String], lineOffsets: [Int],
        into result: NSMutableAttributedString, configuration: Configuration
    ) {
        let lineIndex = block.lineRange.lowerBound
        let line = lines[lineIndex]
        guard !line.isEmpty else { return }
        let lineOffset = lineOffsets[lineIndex]

        add(.font, headingFont(level: level, base: configuration.baseFont), NSRange(location: lineOffset, length: line.utf16.count), in: result)

        guard let prefixCharCount = headingPrefixCharCount(line) else { return }
        let prefixUTF16Length = String(line.prefix(prefixCharCount)).utf16.count
        let prefixRange = NSRange(location: lineOffset, length: prefixUTF16Length)
        add(MarkdownEditorAttribute.syntax, true, prefixRange, in: result)
        add(MarkdownEditorAttribute.lineCommand, true, prefixRange, in: result)
        add(.foregroundColor, configuration.syntaxColor, prefixRange, in: result)

        let contentText = String(line.dropFirst(prefixCharCount))
        styleInlineSpans(in: contentText, offset: lineOffset + prefixUTF16Length, into: result, configuration: configuration)
    }

    private static func styleParagraph(
        block: Block, lines: [String], lineOffsets: [Int],
        into result: NSMutableAttributedString, configuration: Configuration
    ) {
        for lineIndex in block.lineRange {
            let line = lines[lineIndex]
            guard !line.isEmpty else { continue }
            styleInlineSpans(in: line, offset: lineOffsets[lineIndex], into: result, configuration: configuration)
        }
    }

    private static func styleListItem(
        block: Block, lines: [String], lineOffsets: [Int],
        into result: NSMutableAttributedString, configuration: Configuration
    ) {
        let lineIndex = block.lineRange.lowerBound
        let line = lines[lineIndex]
        guard !line.isEmpty, let prefixCharCount = listMarkerPrefixCharCount(line) else { return }
        let lineOffset = lineOffsets[lineIndex]
        let prefixUTF16Length = String(line.prefix(prefixCharCount)).utf16.count
        let markerRange = NSRange(location: lineOffset, length: prefixUTF16Length)
        // Markers are always shown (never tagged `.syntax`) — Obsidian-style
        // persistent structure markers, not collapsible delimiters.
        add(.foregroundColor, configuration.syntaxColor, markerRange, in: result)

        let contentText = String(line.dropFirst(prefixCharCount))
        styleInlineSpans(in: contentText, offset: lineOffset + prefixUTF16Length, into: result, configuration: configuration)
    }

    private static func styleBlockquote(
        block: Block, lines: [String], lineOffsets: [Int],
        into result: NSMutableAttributedString, configuration: Configuration
    ) {
        for lineIndex in block.lineRange {
            let line = lines[lineIndex]
            guard let prefixCharCount = blockquotePrefixCharCount(line) else { continue }
            let lineOffset = lineOffsets[lineIndex]
            let prefixUTF16Length = String(line.prefix(prefixCharCount)).utf16.count
            let prefixRange = NSRange(location: lineOffset, length: prefixUTF16Length)
            add(.foregroundColor, configuration.quoteColor, prefixRange, in: result)

            if lineIndex == block.lineRange.lowerBound {
                // Only the first line's ">" collapses on caret-away for now;
                // later lines of a multi-line quote stay visible (see the
                // type-level doc comment).
                add(MarkdownEditorAttribute.syntax, true, prefixRange, in: result)
                add(MarkdownEditorAttribute.lineCommand, true, prefixRange, in: result)
            }

            let contentText = String(line.dropFirst(prefixCharCount))
            let contentOffset = lineOffset + prefixUTF16Length
            add(.foregroundColor, configuration.quoteColor, NSRange(location: contentOffset, length: contentText.utf16.count), in: result)
            styleInlineSpans(in: contentText, offset: contentOffset, into: result, configuration: configuration)
        }
    }

    private static func styleCodeBlock(
        block: Block, lineOffsets: [Int],
        into result: NSMutableAttributedString, configuration: Configuration
    ) {
        guard let first = block.lineRange.first else { return }
        let fullRange = NSRange(location: lineOffsets[first], length: block.rawText.utf16.count)
        add(.font, configuration.codeFont, fullRange, in: result)
        add(.backgroundColor, configuration.codeBackground, fullRange, in: result)
        // Fence markers ("```") are left visible in this phase — see the
        // type-level doc comment; a code-block "chrome" pass (language
        // label, copy button) is a natural place to revisit this.
    }

    // MARK: - Inline styling

    private static func styleInlineSpans(
        in text: String, offset: Int,
        into result: NSMutableAttributedString, configuration: Configuration
    ) {
        guard !text.isEmpty else { return }
        let spans = MarkdownDocumentModel.parseInlineSpans(in: text)
        for span in spans {
            let full = shifted(span.range, by: offset)
            let opening = shifted(span.openingMarkerRange, by: offset)
            let closing = shifted(span.closingMarkerRange, by: offset)
            let content = shifted(span.contentRange, by: offset)

            switch span.kind {
            case .bold:
                addSymbolicTrait(.bold, over: content, in: result)
            case .italic:
                addSymbolicTrait(.italic, over: content, in: result)
            case .strikethrough:
                add(.strikethroughStyle, NSUnderlineStyle.single.rawValue, content, in: result)
            case .inlineCode:
                add(.font, configuration.codeFont, full, in: result)
                add(.backgroundColor, configuration.codeBackground, full, in: result)
            case .link:
                add(.foregroundColor, configuration.linkColor, content, in: result)
                add(.underlineStyle, NSUnderlineStyle.single.rawValue, content, in: result)
            }

            for markerRange in [opening, closing] where markerRange.length > 0 {
                add(MarkdownEditorAttribute.syntax, true, markerRange, in: result)
                add(MarkdownEditorAttribute.commandSpan, NSValue(range: full), markerRange, in: result)
                add(.foregroundColor, configuration.syntaxColor, markerRange, in: result)
            }
        }
    }

    private static func addSymbolicTrait(_ trait: NSFontDescriptor.SymbolicTraits, over range: NSRange, in result: NSMutableAttributedString) {
        guard let clampedRange = clamped(range, to: result.length) else { return }
        result.enumerateAttribute(.font, in: clampedRange, options: []) { value, subrange, _ in
            let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(trait))
            let newFont = NSFont(descriptor: descriptor, size: base.pointSize) ?? base
            result.addAttribute(.font, value: newFont, range: subrange)
        }
    }

    // MARK: - Prefix-length helpers
    //
    // These mirror (deliberately, not by sharing code) the block-classifying
    // logic in `MarkdownDocumentModel` closely enough to size a "prefix"
    // range for styling. They return *character* counts (not UTF-16), which
    // callers convert via `String(line.prefix(n)).utf16.count` — safe even
    // if a future prefix ever contained a multi-scalar grapheme.

    private static func headingPrefixCharCount(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var count = 0
        for char in line {
            if char == "#" {
                count += 1
            } else if char == " " {
                return count + 1
            } else {
                return nil
            }
        }
        return nil
    }

    private static func blockquotePrefixCharCount(_ line: String) -> Int? {
        guard line.hasPrefix(">") else { return nil }
        let afterMarker = line.index(after: line.startIndex)
        if afterMarker < line.endIndex, line[afterMarker] == " " { return 2 }
        return 1
    }

    private static func listMarkerPrefixCharCount(_ line: String) -> Int? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        var idx = line.index(line.startIndex, offsetBy: leadingSpaces)
        var count = leadingSpaces

        if line[idx...].hasPrefix("- ") {
            count += 2
            idx = line.index(idx, offsetBy: 2)
        } else if line[idx...].hasPrefix("* ") {
            count += 2
            idx = line.index(idx, offsetBy: 2)
        } else {
            var digits = 0
            var j = idx
            while j < line.endIndex, line[j].isNumber {
                digits += 1
                j = line.index(after: j)
            }
            guard digits > 0, j < line.endIndex, line[j] == "." else { return nil }
            j = line.index(after: j)
            guard j < line.endIndex, line[j] == " " else { return nil }
            j = line.index(after: j)
            count += digits + 2
            idx = j
        }

        let rest = line[idx...]
        if rest.hasPrefix("[ ] ") {
            count += 4
        } else if rest == "[ ]" {
            count += 3
        } else if rest.lowercased().hasPrefix("[x] ") {
            count += 4
        } else if rest.lowercased() == "[x]" {
            count += 3
        }

        return count
    }

    private static func headingFont(level: Int, base: NSFont) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = 18
        case 2: size = 16
        case 3: size = 15
        default: size = 14
        }
        let weight: NSFont.Weight = level <= 2 ? .semibold : .medium
        return .systemFont(ofSize: size, weight: weight)
    }

    // MARK: - Range utilities

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    /// Clamps `range` into `[0, length)`, returning `nil` if nothing of it survives.
    /// Cheap defensive insurance around the manual UTF-16 offset arithmetic above.
    private static func clamped(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location >= 0, range.location <= length else { return nil }
        let available = length - range.location
        let clampedLength = min(max(range.length, 0), available)
        guard clampedLength > 0 else { return nil }
        return NSRange(location: range.location, length: clampedLength)
    }

    private static func add(_ key: NSAttributedString.Key, _ value: Any, _ range: NSRange, in result: NSMutableAttributedString) {
        guard let safe = clamped(range, to: result.length) else { return }
        result.addAttribute(key, value: value, range: safe)
    }
}

private typealias Block = MarkdownDocumentModel.Block
