import XCTest
@testable import MeetMemo

final class MeetingStructuredExtractorTests: XCTestCase {
    func testDecodeResultParsesStructuredSummary() throws {
        let response = """
        ```json
        {
          "one_liner": "确认发布节奏和风险处理方案",
          "host": "Ada",
          "location": "线上",
          "discussions": [
            {
              "title": "发布节奏",
              "summary": "团队讨论了灰度发布和一次性发布的利弊。",
              "consensus": "先灰度 20%，再扩大范围。",
              "has_consensus": true
            }
          ],
          "decisions": [
            {
              "title": "采用灰度发布",
              "owner": "Ben",
              "reason": "降低上线风险",
              "confidence": "high",
              "source_excerpt": "先灰度 20%"
            }
          ],
          "risks": [
            {
              "title": "监控覆盖不足",
              "severity": "urgent",
              "mitigation": "补齐核心指标",
              "owner": "Cara"
            }
          ],
          "open_questions": [
            {
              "question": "是否需要回滚演练？",
              "owner": "Dan",
              "next_step": "周五前确认"
            }
          ],
          "milestones": [
            {
              "title": "灰度上线",
              "description": "完成首批用户发布",
              "target_date": "下周一"
            }
          ]
        }
        ```
        """

        let result = try MeetingStructuredExtractor.decodeResult(from: response)

        XCTAssertEqual(result.oneLiner, "确认发布节奏和风险处理方案")
        XCTAssertEqual(result.host, "Ada")
        XCTAssertEqual(result.location, "线上")
        XCTAssertEqual(result.discussions.first?.title, "发布节奏")
        XCTAssertEqual(result.decisions.first?.confidence, "high")
        XCTAssertEqual(result.risks.first?.severity, "medium")
        XCTAssertEqual(result.openQuestions.first?.nextStep, "周五前确认")
        XCTAssertEqual(result.milestones.first?.targetDate, "下周一")
    }

    func testDecodeResultRejectsInvalidJSON() {
        XCTAssertThrowsError(try MeetingStructuredExtractor.decodeResult(from: "not json"))
    }
}
