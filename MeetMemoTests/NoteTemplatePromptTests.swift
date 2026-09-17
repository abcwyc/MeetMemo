import XCTest
@testable import MeetMemo

final class NoteTemplatePromptTests: XCTestCase {
    func testDefaultTemplatesUsePromptOnly() {
        for template in NoteTemplate.defaultTemplates() {
            XCTAssertTrue(template.sections.isEmpty, "\(template.title) should use a single prompt instead of fixed sections.")
            XCTAssertFalse(template.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testLegacySectionsAreMergedIntoPrompt() {
        let template = NoteTemplate(
            title: "旧模板",
            context: "请生成会议纪要。",
            sections: [
                TemplateSection(title: "行动项", description: "列出负责人和截止时间。")
            ]
        )

        let migrated = template.migratedToPromptOnly()

        XCTAssertTrue(migrated.sections.isEmpty)
        XCTAssertTrue(migrated.context.contains("请生成会议纪要。"))
        XCTAssertTrue(migrated.context.contains("行动项"))
        XCTAssertTrue(migrated.context.contains("列出负责人和截止时间。"))
    }

    func testAnalysisTemplatesDeclareEvidenceBoundaries() {
        let templates = Dictionary(
            uniqueKeysWithValues: NoteTemplate.defaultTemplates().map { ($0.title, $0.context) }
        )

        XCTAssertTrue(templates["客户需求访谈"]?.contains("分析判断") == true)
        XCTAssertTrue(templates["客户需求访谈"]?.contains("优先级只在客户明确表达") == true)
        XCTAssertFalse(templates["需求提报"]?.contains("基于背景判断应当纳入") == true)
        XCTAssertTrue(templates["招聘面试"]?.contains("信息不足，暂不判断") == true)
    }
}
