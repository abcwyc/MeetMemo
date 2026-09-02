import XCTest
@testable import MeetMemo

final class MeetingMarkdownExporterTests: XCTestCase {
    func testGenerateNotesMarkdownIncludesMetadataAndPreservesMarkdown() {
        let meetingDate = Date(timeIntervalSince1970: 1_000)
        let exportDate = Date(timeIntervalSince1970: 2_000)
        let meeting = Meeting(
            date: meetingDate,
            title: "产品评审",
            generatedNotes: "## 结论\n\n- 保留 **Markdown**\n- [查看文档](https://example.com)",
            speakerParticipantNames: ["张三", "李\"四"],
            host: "主持人",
            location: "会议室 A"
        )

        let markdown = MeetingMarkdownExporter.generateNotesMarkdown(for: meeting, exportDate: exportDate)

        XCTAssertTrue(markdown.hasPrefix("---\ntitle: \"产品评审\"\ndate: \"1970-01-01T00:16:40Z\"\n"))
        XCTAssertTrue(markdown.contains("location: \"会议室 A\""))
        XCTAssertTrue(markdown.contains("host: \"主持人\""))
        XCTAssertTrue(markdown.contains("  - \"李\\\"四\""))
        XCTAssertTrue(markdown.contains("exported_at: \"1970-01-01T00:33:20Z\""))
        XCTAssertTrue(markdown.hasSuffix("## 结论\n\n- 保留 **Markdown**\n- [查看文档](https://example.com)\n"))
    }

    func testGenerateNotesMarkdownOmitsEmptyOptionalMetadata() {
        let meeting = Meeting(
            title: "  ",
            generatedNotes: "  # 会议内容  \n",
            host: "\n",
            location: "  ",
            speakerParticipantNames: []
        )

        let markdown = MeetingMarkdownExporter.generateNotesMarkdown(
            for: meeting,
            exportDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(markdown.contains("title: \"会议纪要\""))
        XCTAssertFalse(markdown.contains("location:"))
        XCTAssertFalse(markdown.contains("host:"))
        XCTAssertFalse(markdown.contains("attendees:"))
        XCTAssertTrue(markdown.hasSuffix("# 会议内容\n"))
    }
}
