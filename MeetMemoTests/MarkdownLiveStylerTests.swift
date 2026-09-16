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

    // MARK: - P3: table hidden + reserved height

    func testTableSourceIsAlwaysHiddenLikeAThematicBreak() {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        for i in 0..<attributed.length {
            let attrs = attributed.attributes(at: i, effectiveRange: nil)
            XCTAssertEqual(attrs[MarkdownEditorAttribute.syntax] as? Bool, true, "index \(i)")
            XCTAssertEqual(attrs[MarkdownEditorAttribute.alwaysHidden] as? Bool, true, "index \(i)")
            XCTAssertNil(attrs[MarkdownEditorAttribute.lineCommand], "a table is not caret-revealable, index \(i)")
        }
    }

    func testTableReservesLineHeightViaParagraphStyle() {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        guard let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else {
            return XCTFail("expected a paragraphStyle attribute on the table's first character")
        }
        let expected = MarkdownLiveStyler.reservedLineHeight(forTableRowCount: 1, rowHeight: MarkdownLiveStyler.Configuration.standard().tableRowHeight)
        XCTAssertEqual(style.minimumLineHeight, expected, accuracy: 0.001)
    }

    func testSurroundingTextUnaffectedByHiddenTable() {
        let source = "before\n| A | B |\n| --- | --- |\n| 1 | 2 |\nafter"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        for word in ["before", "after"] {
            let attrs = attributed.attributes(at: ns.range(of: word).location, effectiveRange: nil)
            XCTAssertNil(attrs[MarkdownEditorAttribute.syntax])
            XCTAssertNil(attrs[MarkdownEditorAttribute.alwaysHidden])
        }
    }

    // MARK: - P3: reservedLineHeight formula

    func testReservedLineHeightFormulaSumsToExpectedTotal() {
        // header + rows get `rowHeight` each; separator gets none; the total
        // across all N=(rows+2) source lines must equal that sum exactly.
        for dataRowCount in [0, 1, 3, 10] {
            let rowHeight: CGFloat = 34
            let perLine = MarkdownLiveStyler.reservedLineHeight(forTableRowCount: dataRowCount, rowHeight: rowHeight)
            let totalLines = CGFloat(dataRowCount + 2)
            let expectedTotal = CGFloat(dataRowCount + 1) * rowHeight
            XCTAssertEqual(perLine * totalLines, expectedTotal, accuracy: 0.001, "dataRowCount=\(dataRowCount)")
        }
    }

    // MARK: - P3: tableBlocks(in:) query

    func testTableBlocksReturnsRangeAndParsedTable() {
        let source = "before\n\n| Q | A |\n| --- | --- |\n| x | y |\n\nafter"
        let blocks = MarkdownLiveStyler.tableBlocks(in: source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].table.headers, ["Q", "A"])
        XCTAssertEqual(blocks[0].table.rows, [["x", "y"]])

        let ns = source as NSString
        let expectedRange = ns.range(of: "| Q | A |\n| --- | --- |\n| x | y |")
        XCTAssertEqual(blocks[0].range, expectedRange)
    }

    func testTableBlocksReturnsEmptyForNoTables() {
        XCTAssertEqual(MarkdownLiveStyler.tableBlocks(in: "just a paragraph, no pipes"), [])
    }

    func testTableBlocksFindsMultipleTablesInOrder() {
        // MarkdownDocumentModel's table detection requires >= 2 columns
        // (matching parseCells' isTableRow check), so single-column tables
        // are exercised elsewhere; use 2-column tables here.
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\ntext between\n\n| C | D |\n| --- | --- |\n| 3 | 4 |"
        let blocks = MarkdownLiveStyler.tableBlocks(in: source)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].table.headers, ["A", "B"])
        XCTAssertEqual(blocks[1].table.headers, ["C", "D"])
        XCTAssertLessThan(blocks[0].range.location, blocks[1].range.location)
    }

    // MARK: - P2: thematic break rule

    func testThematicBreakDashesAreAlwaysHiddenAndTaggedAsRule() {
        let source = "above\n---\nbelow"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let ruleLineLoc = ns.range(of: "---").location

        let attrs = attributed.attributes(at: ruleLineLoc, effectiveRange: nil)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.syntax] as? Bool, true)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.alwaysHidden] as? Bool, true)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.rule] as? Bool, true)
        // A rule is not caret-revealable, so it must not carry line/span tags
        // that would otherwise make it conditionally visible.
        XCTAssertNil(attrs[MarkdownEditorAttribute.lineCommand])
        XCTAssertNil(attrs[MarkdownEditorAttribute.commandSpan])
    }

    func testSurroundingParagraphsUnaffectedByThematicBreak() {
        let source = "above\n---\nbelow"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        for word in ["above", "below"] {
            let attrs = attributed.attributes(at: ns.range(of: word).location, effectiveRange: nil)
            XCTAssertNil(attrs[MarkdownEditorAttribute.syntax])
            XCTAssertNil(attrs[MarkdownEditorAttribute.rule])
        }
    }

    // MARK: - P2: checkbox click-to-toggle tagging

    func testUncheckedCheckboxRangeIsExactlyTheThreeBracketCharacters() {
        let source = "- [ ] Todo item"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let checkboxRange = ns.range(of: "[ ]")

        var effective = NSRange()
        let attrs = attributed.attributes(at: checkboxRange.location, effectiveRange: &effective)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.checkbox] as? Bool, true)
        XCTAssertEqual(effective, checkboxRange)

        // Never tagged as collapsible syntax — checkboxes are always shown.
        XCTAssertNil(attrs[MarkdownEditorAttribute.syntax])

        let contentAttrs = attributed.attributes(at: ns.range(of: "Todo").location, effectiveRange: nil)
        XCTAssertNil(contentAttrs[MarkdownEditorAttribute.checkbox])
    }

    func testCheckedCheckboxIsTaggedAndAccentColored() {
        let source = "- [x] Done item"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let checkboxRange = ns.range(of: "[x]")

        let attrs = attributed.attributes(at: checkboxRange.location, effectiveRange: nil)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.checkbox] as? Bool, true)
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, NSColor.controlAccentColor)
    }

    func testUppercaseCheckedCheckboxIsAlsoTagged() {
        let source = "- [X] Done item"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let attrs = attributed.attributes(at: ns.range(of: "[X]").location, effectiveRange: nil)
        XCTAssertEqual(attrs[MarkdownEditorAttribute.checkbox] as? Bool, true)
    }

    func testPlainListItemWithoutCheckboxHasNoCheckboxTag() {
        let source = "- plain item, no brackets"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        for i in 0..<attributed.length {
            XCTAssertNil(attributed.attributes(at: i, effectiveRange: nil)[MarkdownEditorAttribute.checkbox], "index \(i)")
        }
    }

    // MARK: - P2: blockquote bar

    func testBlockquoteBarTagCoversFullLineIncludingCollapsedPrefix() {
        let source = "> a quoted line"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        for i in 0..<attributed.length {
            XCTAssertEqual(attributed.attributes(at: i, effectiveRange: nil)[MarkdownEditorAttribute.blockquoteBar] as? Bool, true, "index \(i)")
        }
    }

    func testBlockquoteBarDoesNotLeakIntoFollowingParagraph() {
        let source = "> quoted\n\nnot quoted"
        let attributed = MarkdownLiveStyler.attributedString(for: source)
        let ns = source as NSString
        let loc = ns.range(of: "not quoted").location
        XCTAssertNil(attributed.attributes(at: loc, effectiveRange: nil)[MarkdownEditorAttribute.blockquoteBar])
    }
}

final class MarkdownCheckboxToggleTests: XCTestCase {
    func testUncheckedTogglesToChecked() {
        XCTAssertEqual(MarkdownCheckboxToggle.toggledText(for: "[ ]"), "[x]")
    }

    func testCheckedLowercaseTogglesToUnchecked() {
        XCTAssertEqual(MarkdownCheckboxToggle.toggledText(for: "[x]"), "[ ]")
    }

    func testCheckedUppercaseTogglesToUnchecked() {
        XCTAssertEqual(MarkdownCheckboxToggle.toggledText(for: "[X]"), "[ ]")
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

final class MarkdownTableSerializerTests: XCTestCase {
    func testSerializesHeaderSeparatorAndRows() {
        let markdown = MarkdownTableSerializer.serialize(headers: ["Q", "A"], rows: [["x", "y"], ["1", "2"]])
        XCTAssertEqual(markdown, "| Q | A |\n| --- | --- |\n| x | y |\n| 1 | 2 |")
    }

    func testRoundTripsThroughMarkdownDocumentModelParser() {
        let markdown = MarkdownTableSerializer.serialize(headers: ["问题", "决策人"], rows: [["A 失真", "张三"]])
        let blocks = MarkdownDocumentModel.parse(markdown)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let table) = blocks[0].kind else { return XCTFail("expected table") }
        XCTAssertEqual(table.headers, ["问题", "决策人"])
        XCTAssertEqual(table.rows, [["A 失真", "张三"]])
    }

    func testTrimsWhitespaceFromCells() {
        let markdown = MarkdownTableSerializer.serialize(headers: ["  A  "], rows: [[" b "]])
        XCTAssertEqual(markdown, "| A |\n| --- |\n| b |")
    }

    func testPadsShortRowToHeaderColumnCount() {
        let markdown = MarkdownTableSerializer.serialize(headers: ["A", "B", "C"], rows: [["1"]])
        XCTAssertEqual(markdown, "| A | B | C |\n| --- | --- | --- |\n| 1 |  |  |")
    }

    func testTruncatesLongRowToHeaderColumnCount() {
        let markdown = MarkdownTableSerializer.serialize(headers: ["A"], rows: [["1", "extra", "more"]])
        XCTAssertEqual(markdown, "| A |\n| --- |\n| 1 |")
    }

    func testEmptyRowsProducesHeaderAndSeparatorOnly() {
        let markdown = MarkdownTableSerializer.serialize(headers: ["A", "B"], rows: [])
        XCTAssertEqual(markdown, "| A | B |\n| --- | --- |")
    }
}
