import XCTest
@testable import MeetMemo

final class HTMLSanitizerTests: XCTestCase {
    func testSanitizerRemovesExecutableAndExternalContent() {
        let html = """
        <div class="card unknown" onclick="alert(1)">
          <script>alert('x')</script>
          <img src="https://example.com/pixel.png" onerror="alert(1)">
          <iframe src="https://example.com"></iframe>
          <span class="badge badge-success">完成</span>
        </div>
        """

        let sanitized = HTMLSanitizer.sanitizeDiagramHTML(html)

        XCTAssertFalse(sanitized.lowercased().contains("<script"))
        XCTAssertFalse(sanitized.lowercased().contains("<img"))
        XCTAssertFalse(sanitized.lowercased().contains("<iframe"))
        XCTAssertFalse(sanitized.lowercased().contains("onclick"))
        XCTAssertFalse(sanitized.lowercased().contains("onerror"))
        XCTAssertFalse(sanitized.contains("unknown"))
        XCTAssertTrue(sanitized.contains(#"class="card""#))
        XCTAssertTrue(sanitized.contains(#"class="badge badge-success""#))
    }

    func testSanitizerDropsUnsafeInlineStylesButKeepsSafeDiagramMarkup() {
        let html = """
        <table>
          <tr>
            <td colspan="2" style="background: var(--bg-info); color: #185FA5;">阶段一</td>
            <td rowspan="99" style="background: url(https://example.com/a.png)">bad</td>
          </tr>
        </table>
        """

        let sanitized = HTMLSanitizer.sanitizeDiagramHTML(html)

        XCTAssertTrue(sanitized.contains("<table>"))
        XCTAssertTrue(sanitized.contains(#"colspan="2""#))
        XCTAssertTrue(sanitized.contains("background: var(--bg-info); color: #185FA5;"))
        XCTAssertFalse(sanitized.contains("rowspan"))
        XCTAssertFalse(sanitized.lowercased().contains("url("))
    }
}
