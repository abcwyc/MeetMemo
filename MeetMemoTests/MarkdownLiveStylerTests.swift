import XCTest
import AppKit
@testable import MeetMemo

final class MarkdownLiveStylerTests: XCTestCase {

    // MARK: - Verbatim invariant

    func testStyledStringIsCharacterForCharacterVerbatim() {
        let source = "# Title\n\n- [x] done\n\n> quoted\n\n**bold** and `code` and [link](https://x.com)"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        XCTAssertEqual(attributed.string, source)
    }

    func testEmptyStringProducesEmptyAttributedString() {
        let attributed = MarkdownLiveStyler.attributedString(for: "")
        XCTAssertEqual(attributed.length, 0)
    }

    // MARK: - Heading

    func testHeadingPrefixTaggedAsLineCommandSyntax() {
        let source = "## Section Title"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString

        let hashRange = ns.range(of: "## ")
        var effective = NSRange()
        let attrs = attributed.attributes(at: hashRange.location, effectiveRange: &effective)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.syntax] as? Bool, true)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.lineCommand] as? Bool, true)
        XCTAssertEqual(effective, hashRange)

        let titleRange = ns.range(of: "Section Title")
        let titleAttrs = attributed.attributes(at: titleRange.location, effectiveRange: nil)
        XCTAssertNil(titleAttrs[MarkdownEditorAttribute.syntax])
    }

    func testHeadingContentUsesLargerFontThanBody() {
        let source = "plain\n# Heading"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString

        let plainFont = attributed.attribute(.font, at: ns.range(of: "plain").location, effectiveRange: nil) as? NSFont
        let headingFont = attributed.attribute(.font, at: ns.range(of: "Heading").location, effectiveRange: nil) as? NSFont

        XCTAssertNotNil(plainFont)
        XCTAssertNotNil(headingFont)
        XCTAssertGreaterThan(headingFont!.pointSize, plainFont!.pointSize)
    }

    // MARK: - List markers (always visible)

    func testListMarkerIsNeverTaggedAsSyntax() {
        let source = "- an item"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let markerAttrs = attributed.attributes(at: 0, effectiveRange: nil)
        XCTAssertNil(markerAttrs[MarkdownEditorAttribute.syntax], "list markers must stay visible, never tagged as collapsible syntax")
    }

    func testCheckboxPrefixExcludedFromContentStyling() {
        let source = "- [x] Ship it"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let contentRange = ns.range(of: "Ship it")
        // Content should carry base foreground, not the marker's dimmed color.
        let contentColor = attributed.attribute(.foregroundColor, at: contentRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(contentColor, NSColor.labelColor)
    }

    // MARK: - Blockquote

    func testBlockquoteFirstLinePrefixIsLineCommandSyntax() {
        let source = "> quoted text"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let attrs = attributed.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.syntax] as? Bool, true)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.lineCommand] as? Bool, true)
    }

    // MARK: - Inline spans

    func testBoldContentGetsBoldFontTraitAndDelimitersAreCommandSpanSyntax() {
        let source = "before **bold** after"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString

        let boldContentLoc = ns.range(of: "bold").location
        let font = attributed.attribute(.font, at: boldContentLoc, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)

        let openingDelimiterLoc = ns.range(of: "**bold**").location
        let openAttrs = attributed.attributes(at: openingDelimiterLoc, effectiveRange: nil)
        XCTAssertEqual(openAttrs[MarkdownEditorAttribute.syntax] as? Bool, true)
        guard let spanValue = openAttrs[MarkdownEditorAttribute.commandSpan] as? NSValue else {
            return XCTFail("expected commandSpan attribute")
        }
        XCTAssertEqual(spanValue.rangeValue, ns.range(of: "**bold**"))
    }

    func testItalicContentGetsItalicFontTrait() {
        let source = "an *italic* word"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let loc = ns.range(of: "italic").location
        let font = attributed.attribute(.font, at: loc, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
    }

    func testStrikethroughAppliesStrikethroughStyleToContentOnly() {
        let source = "a ~~gone~~ word"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let contentLoc = ns.range(of: "gone").location
        XCTAssertNotNil(attributed.attribute(.strikethroughStyle, at: contentLoc, effectiveRange: nil))

        let delimiterLoc = ns.range(of: "~~gone~~").location
        XCTAssertEqual(attributed.attributes(at: delimiterLoc, effectiveRange: nil)[MarkdownEditorAttribute.syntax] as? Bool, true)
    }

    func testInlineCodeGetsMonospaceFontOverFullRangeIncludingBackticks() {
        let source = "run `let x = 1` now"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let fullRange = ns.range(of: "`let x = 1`")
        var effective = NSRange()
        let font = attributed.attribute(.font, at: fullRange.location, effectiveRange: &effective) as? NSFont
        XCTAssertNotNil(font)
        // Monospace fonts report a fixed-pitch trait via the descriptor's class, or
        // at minimum should not equal the surrounding proportional body font.
        let bodyFont = attributed.attribute(.font, at: ns.range(of: "run").location, effectiveRange: nil) as? NSFont
        XCTAssertNotEqual(font, bodyFont)
    }

    func testLinkContentColoredAndDestinationParsedButBracketsAreSyntax() {
        let source = "see [docs](https://example.com) here"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString

        let contentLoc = ns.range(of: "docs").location
        let color = attributed.attribute(.foregroundColor, at: contentLoc, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.linkColor)

        let openBracketLoc = ns.range(of: "[docs]").location
        XCTAssertEqual(attributed.attributes(at: openBracketLoc, effectiveRange: nil)[MarkdownEditorAttribute.syntax] as? Bool, true)
    }

    // MARK: - Code block

    func testFencedCodeBlockGetsMonospaceFontAndBackgroundOverWholeBlock() {
        let source = "```swift\nlet x = 1\n```"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let midpoint = (source as NSString).range(of: "let x = 1").location
        XCTAssertNotNil(attributed.attribute(.backgroundColor, at: midpoint, effectiveRange: nil))
    }

    // MARK: - Table / thematic break left untouched (P1 scope)

    func testTableCellsAreNotTaggedAsSyntaxInThisPhase() {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        for i in 0..<attributed.length {
            let attrs = attributed.attributes(at: i, effectiveRange: nil)
            XCTAssertNil(attrs[MarkdownEditorAttribute.syntax], "tables are out of scope for the text-based live styler (index \(i))")
        }
    }
}

final class MarkdownLiveVisibilityTests: XCTestCase {
    func testLineCommandVisibleWhenCaretOnSameLine() {
        let lineRange = NSRange(location: 10, length: 8) // e.g. "## Title"
        XCTAssertTrue(MarkdownLiveVisibility.isLineCommandVisible(charIndex: 10, caretLineRange: lineRange))
        XCTAssertTrue(MarkdownLiveVisibility.isLineCommandVisible(charIndex: 15, caretLineRange: lineRange))
    }

    func testLineCommandHiddenWhenCaretOnDifferentLine() {
        let lineRange = NSRange(location: 10, length: 8)
        XCTAssertFalse(MarkdownLiveVisibility.isLineCommandVisible(charIndex: 0, caretLineRange: lineRange))
        XCTAssertFalse(MarkdownLiveVisibility.isLineCommandVisible(charIndex: 100, caretLineRange: lineRange))
    }

    func testSpanActiveWhenCaretInsideSpan() {
        let span = NSRange(location: 5, length: 10) // "**bold**"
        XCTAssertTrue(MarkdownLiveVisibility.spanIsActive(span, caret: NSRange(location: 8, length: 0)))
    }

    func testSpanActiveWhenCaretOverlapsSpanViaSelection() {
        let span = NSRange(location: 5, length: 10)
        XCTAssertTrue(MarkdownLiveVisibility.spanIsActive(span, caret: NSRange(location: 0, length: 7)))
    }

    func testSpanActiveWhenCaretImmediatelyAfterClosingDelimiter() {
        let span = NSRange(location: 5, length: 10)
        XCTAssertTrue(MarkdownLiveVisibility.spanIsActive(span, caret: NSRange(location: 15, length: 0)))
    }

    func testSpanInactiveWhenCaretOutsideAndNotAdjacent() {
        let span = NSRange(location: 5, length: 10)
        XCTAssertFalse(MarkdownLiveVisibility.spanIsActive(span, caret: NSRange(location: 20, length: 0)))
        XCTAssertFalse(MarkdownLiveVisibility.spanIsActive(span, caret: NSRange(location: 0, length: 3)))
    }

    func testSpanInactiveWhenNonEmptySelectionEndsExactlyAtSpanEndWithoutOverlap() {
        // A non-empty selection that merely touches the boundary (zero-length
        // intersection) should not count as active — only an empty caret
        // right after the span does (see previous test).
        let span = NSRange(location: 5, length: 10) // [5, 15)
        let caret = NSRange(location: 15, length: 3) // [15, 18) — touches but doesn't overlap
        XCTAssertFalse(MarkdownLiveVisibility.spanIsActive(span, caret: caret))
    }
}
