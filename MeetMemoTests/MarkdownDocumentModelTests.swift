import XCTest
@testable import MeetMemo

final class MarkdownDocumentModelTests: XCTestCase {

    // MARK: - Block kinds

    func testHeadingLevelsAndLineRange() {
        let blocks = MarkdownDocumentModel.parse("# Title\n## Sub\n###### Deep")

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(blocks[0].lineRange, 0...0)
        XCTAssertEqual(blocks[0].content?.text, "Title")

        XCTAssertEqual(blocks[1].kind, .heading(level: 2))
        XCTAssertEqual(blocks[2].kind, .heading(level: 6))
    }

    func testHeadingRequiresSpaceAfterHashes() {
        let blocks = MarkdownDocumentModel.parse("#NotAHeading")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    func testParagraphMergesConsecutiveLines() {
        let blocks = MarkdownDocumentModel.parse("Line one\nLine two\n\nLine three alone")

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[0].lineRange, 0...1)
        XCTAssertEqual(blocks[0].content?.text, "Line one\nLine two")
        XCTAssertEqual(blocks[1].kind, .blank)
        XCTAssertEqual(blocks[2].kind, .paragraph)
        XCTAssertEqual(blocks[2].content?.text, "Line three alone")
    }

    func testParagraphStopsAtHeadingListQuoteTableFenceRule() {
        let blocks = MarkdownDocumentModel.parse("A paragraph\n# Heading breaks it")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].lineRange, 0...0)
        XCTAssertEqual(blocks[1].kind, .heading(level: 1))
    }

    func testUnorderedListItemsWithNesting() {
        let blocks = MarkdownDocumentModel.parse("- top\n    - nested\n* also top")

        XCTAssertEqual(blocks.count, 3)
        guard case .listItem(let ordered0, let indent0, let marker0, let checkbox0) = blocks[0].kind else {
            return XCTFail("expected listItem")
        }
        XCTAssertFalse(ordered0)
        XCTAssertEqual(indent0, 0)
        XCTAssertEqual(marker0, "-")
        XCTAssertNil(checkbox0)
        XCTAssertEqual(blocks[0].content?.text, "top")

        guard case .listItem(_, let indent1, _, _) = blocks[1].kind else {
            return XCTFail("expected listItem")
        }
        XCTAssertEqual(indent1, 1)
        XCTAssertEqual(blocks[1].content?.text, "nested")

        guard case .listItem(let ordered2, _, let marker2, _) = blocks[2].kind else {
            return XCTFail("expected listItem")
        }
        XCTAssertFalse(ordered2)
        XCTAssertEqual(marker2, "*")
    }

    func testOrderedListItem() {
        let blocks = MarkdownDocumentModel.parse("1. first\n2. second")
        guard case .listItem(let ordered, _, let marker, _) = blocks[0].kind else {
            return XCTFail("expected listItem")
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(marker, "1.")
        XCTAssertEqual(blocks[0].content?.text, "first")

        guard case .listItem(_, _, let marker2, _) = blocks[1].kind else {
            return XCTFail("expected listItem")
        }
        XCTAssertEqual(marker2, "2.")
    }

    func testTaskListCheckboxes() {
        let blocks = MarkdownDocumentModel.parse("- [ ] todo\n- [x] done\n- [X] also done")

        guard case .listItem(_, _, _, let checkbox0) = blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(checkbox0, false)
        XCTAssertEqual(blocks[0].content?.text, "todo")

        guard case .listItem(_, _, _, let checkbox1) = blocks[1].kind else { return XCTFail() }
        XCTAssertEqual(checkbox1, true)
        XCTAssertEqual(blocks[1].content?.text, "done")

        guard case .listItem(_, _, _, let checkbox2) = blocks[2].kind else { return XCTFail() }
        XCTAssertEqual(checkbox2, true)
        XCTAssertEqual(blocks[2].content?.text, "also done")
    }

    func testBlockquoteSingleAndMultiLine() {
        let blocks = MarkdownDocumentModel.parse("> quoted line one\n> quoted line two\n\nNot quoted")

        XCTAssertEqual(blocks[0].kind, .blockquote)
        XCTAssertEqual(blocks[0].lineRange, 0...1)
        XCTAssertEqual(blocks[0].content?.text, "quoted line one\nquoted line two")
        XCTAssertEqual(blocks[1].kind, .blank)
        XCTAssertEqual(blocks[2].kind, .paragraph)
    }

    func testFencedCodeBlockWithLanguage() {
        let source = "```swift\nlet x = 1\nlet y = 2\n```\nAfter"
        let blocks = MarkdownDocumentModel.parse(source)

        XCTAssertEqual(blocks[0].kind, .codeBlock(language: "swift"))
        XCTAssertEqual(blocks[0].lineRange, 0...3)
        XCTAssertNil(blocks[0].content)
        XCTAssertTrue(blocks[0].rawText.contains("let x = 1"))

        XCTAssertEqual(blocks[1].kind, .paragraph)
        XCTAssertEqual(blocks[1].content?.text, "After")
    }

    func testFencedCodeBlockWithoutLanguageAndUnterminated() {
        let source = "```\nno close fence here"
        let blocks = MarkdownDocumentModel.parse(source)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .codeBlock(language: nil))
        XCTAssertEqual(blocks[0].lineRange, 0...1)
    }

    func testThematicBreakVariants() {
        for marker in ["---", "***", "___", "- - -", "* * *"] {
            let blocks = MarkdownDocumentModel.parse(marker)
            XCTAssertEqual(blocks.count, 1, "marker: \(marker)")
            XCTAssertEqual(blocks[0].kind, .thematicBreak, "marker: \(marker)")
        }
    }

    func testThematicBreakDoesNotShadowTableSeparator() {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let blocks = MarkdownDocumentModel.parse(source)

        XCTAssertEqual(blocks.count, 1)
        guard case .table(let table) = blocks[0].kind else { return XCTFail("expected table") }
        XCTAssertEqual(table.headers, ["A", "B"])
        XCTAssertEqual(table.rows, [["1", "2"]])
        XCTAssertEqual(blocks[0].lineRange, 0...2)
    }

    func testTableWithMultipleRowsAndRaggedColumns() {
        let source = "| 问题 | 结果 | 决策人 |\n| --- | --- | --- |\n| A | B | C |\n| D | E |"
        let blocks = MarkdownDocumentModel.parse(source)

        XCTAssertEqual(blocks.count, 1)
        guard case .table(let table) = blocks[0].kind else { return XCTFail("expected table") }
        XCTAssertEqual(table.headers, ["问题", "结果", "决策人"])
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[1], ["D", "E"])
    }

    func testBlankLines() {
        let blocks = MarkdownDocumentModel.parse("\n   \n")
        XCTAssertEqual(blocks.count, 3)
        for block in blocks {
            XCTAssertEqual(block.kind, .blank)
        }
    }

    // MARK: - Inline spans

    func testInlineBoldAsterisksAndUnderscores() {
        let spans1 = MarkdownDocumentModel.parseInlineSpans(in: "a **bold** b")
        XCTAssertEqual(spans1.count, 1)
        XCTAssertEqual(spans1[0].kind, .bold)
        XCTAssertEqual((spans1[0].range), NSRange(location: 2, length: 8))
        XCTAssertEqual(("a **bold** b" as NSString).substring(with: spans1[0].contentRange), "bold")

        let spans2 = MarkdownDocumentModel.parseInlineSpans(in: "a __bold__ b")
        XCTAssertEqual(spans2.count, 1)
        XCTAssertEqual(spans2[0].kind, .bold)
    }

    func testInlineItalicDoesNotMatchInsideBold() {
        let text = "a **bold text** b"
        let spans = MarkdownDocumentModel.parseInlineSpans(in: text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .bold)
    }

    func testInlineItalicAsteriskAndUnderscore() {
        let spans1 = MarkdownDocumentModel.parseInlineSpans(in: "a *italic* b")
        XCTAssertEqual(spans1.count, 1)
        XCTAssertEqual(spans1[0].kind, .italic)

        let spans2 = MarkdownDocumentModel.parseInlineSpans(in: "a _italic_ b")
        XCTAssertEqual(spans2.count, 1)
        XCTAssertEqual(spans2[0].kind, .italic)
    }

    func testInlineStrikethrough() {
        let spans = MarkdownDocumentModel.parseInlineSpans(in: "a ~~gone~~ b")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .strikethrough)
    }

    func testInlineCodeBindsTighterThanEmphasis() {
        let text = "run `*not italic*` now"
        let spans = MarkdownDocumentModel.parseInlineSpans(in: text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .inlineCode)
        XCTAssertEqual((text as NSString).substring(with: spans[0].contentRange), "*not italic*")
    }

    func testInlineLinkWithDestination() {
        let text = "see [docs](https://example.com/x) here"
        let spans = MarkdownDocumentModel.parseInlineSpans(in: text)
        XCTAssertEqual(spans.count, 1)
        guard case .link(let destination) = spans[0].kind else { return XCTFail("expected link") }
        XCTAssertEqual(destination, "https://example.com/x")
        XCTAssertEqual((text as NSString).substring(with: spans[0].contentRange), "docs")
    }

    func testMultipleNonOverlappingInlineSpansSortedByPosition() {
        let text = "**bold** then `code` then *italic*"
        let spans = MarkdownDocumentModel.parseInlineSpans(in: text)
        XCTAssertEqual(spans.map(\.kind), [.bold, .inlineCode, .italic])
        // Sorted left-to-right and non-overlapping.
        for i in 1..<spans.count {
            XCTAssertGreaterThanOrEqual(spans[i].range.location, spans[i - 1].range.location + spans[i - 1].range.length)
        }
    }

    func testEmptyStringHasNoSpans() {
        XCTAssertEqual(MarkdownDocumentModel.parseInlineSpans(in: ""), [])
    }

    func testMeetingNotesShapedDocument() {
        let source = """
        # 会议纪要

        ## 决策事项
        - [x] 上线新版审批流程
        - [ ] 补充风控文档

        > 需要法务在本周五前review

        | 问题描述 | 讨论结果 | 决策人 |
        | --- | --- | --- |
        | AI 知识库回复失真 | 下线并复查 | 张三 |

        后续将同步 **进展** 到群里。
        """
        let blocks = MarkdownDocumentModel.parse(source)

        XCTAssertEqual(blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(blocks[0].content?.text, "会议纪要")

        let kinds = blocks.map(\.kind)
        XCTAssertTrue(kinds.contains(.heading(level: 2)))
        XCTAssertTrue(kinds.contains { if case .listItem = $0 { return true }; return false })
        XCTAssertTrue(kinds.contains(.blockquote))
        XCTAssertTrue(kinds.contains { if case .table = $0 { return true }; return false })

        let finalParagraph = blocks.last { $0.kind == .paragraph }
        XCTAssertNotNil(finalParagraph?.content?.spans.first { $0.kind == .bold })
    }
}
