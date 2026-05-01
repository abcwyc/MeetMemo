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
}
