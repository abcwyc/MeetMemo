import XCTest
@testable import MeetMemo

final class TranscriptBudgetTests: XCTestCase {

    // MARK: - estimateTokens

    func testEstimateTokensIsZeroForEmptyText() {
        XCTAssertEqual(TranscriptBudget.estimateTokens(""), 0)
    }

    func testEstimateTokensCountsCJKRoughlyOnePerCharacter() {
        // 10 个汉字，CJK 按 ~1 token/字 再上浮 10% → 约 11。
        let tokens = TranscriptBudget.estimateTokens("这是一段中文会议转录文本")
        XCTAssertGreaterThanOrEqual(tokens, 10)
    }

    func testEstimateTokensCountsLatinRoughlyByQuarterChars() {
        // 纯英文按字符数 / 4：明显少于同字符数的中文。
        let english = TranscriptBudget.estimateTokens(String(repeating: "a", count: 40))
        let chinese = TranscriptBudget.estimateTokens(String(repeating: "中", count: 40))
        XCTAssertGreaterThan(english, 0)
        XCTAssertLessThan(english, chinese)
    }

    // MARK: - fit (no compression)

    func testShortTextIsReturnedUnchanged() {
        let text = "发言人 1 · 00:00: 大家好，今天的会议开始。\n发言人 2 · 00:05: 好的。"
        let result = TranscriptBudget.fit(text)
        XCTAssertFalse(result.didCompress)
        XCTAssertEqual(result.text, text)
    }

    func testEmptyTextIsNotCompressed() {
        let result = TranscriptBudget.fit("")
        XCTAssertFalse(result.didCompress)
        XCTAssertEqual(result.text, "")
    }

    // MARK: - fit (compression)

    func testLongTextIsCompressedWithinBudgetKeepingHeadAndTail() {
        let budget = 100
        var lines: [String] = ["HEADSTART 这是开头第一行"]
        for i in 1...300 {
            lines.append("第 \(i) 行中间转录内容，包含一些占位文字以增加长度。")
        }
        lines.append("TAILEND 这是结尾最后一行")
        let text = lines.joined(separator: "\n")

        // 前置条件：原文确实超预算。
        XCTAssertGreaterThan(TranscriptBudget.estimateTokens(text), budget)

        let result = TranscriptBudget.fit(text, tokenBudget: budget)

        XCTAssertTrue(result.didCompress)
        // 首尾保留。
        XCTAssertTrue(result.text.contains("HEADSTART"))
        XCTAssertTrue(result.text.contains("TAILEND"))
        // 含省略标记（中英文版本均含省略号 "…"）。
        XCTAssertTrue(result.text.contains("…"))
        // 结果落入预算。
        XCTAssertLessThanOrEqual(TranscriptBudget.estimateTokens(result.text), budget)
        // 确实变短了。
        XCTAssertLessThan(result.text.count, text.count)
    }

    func testSingleOverlongLineFallsBackToHardTruncate() {
        let budget = 20
        let text = String(repeating: "中", count: 5000) // 单行、无换行
        XCTAssertGreaterThan(TranscriptBudget.estimateTokens(text), budget)

        let result = TranscriptBudget.fit(text, tokenBudget: budget)
        XCTAssertTrue(result.didCompress)
        XCTAssertTrue(result.text.contains("…"))
        XCTAssertLessThan(result.text.count, text.count)
    }
}
