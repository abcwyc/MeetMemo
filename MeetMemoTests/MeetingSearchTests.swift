import XCTest
@testable import MeetMemo

final class MeetingSearchTests: XCTestCase {
    func testSearchMatchesContentPast500CharactersInNotes() {
        let prefixPad = String(repeating: "这是一段填充文字，确保超过五百字限制。", count: 30) // ~600+ chars
        let deepSecret = "超级核心机密关键词XYZ987"
        let fullNotes = "\(prefixPad)\n\(deepSecret)\n其他补充信息。"

        let meeting = Meeting(
            title: "季度架构评审",
            generatedNotes: fullNotes
        )
        let summary = MeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.matches(searchText: "超级核心机密关键词XYZ987"))
        XCTAssertTrue(summary.matches(searchText: "xyz987")) // case-insensitive
        XCTAssertFalse(summary.matches(searchText: "不存在的内容404"))
    }

    func testSearchMatchesSpokenTranscriptChunks() {
        let chunk1 = TranscriptChunk(
            source: .mic,
            text: "我们今天主要讨论离线说话人聚类方案",
            isFinal: true
        )
        let chunk2 = TranscriptChunk(
            source: .system,
            text: "王工建议使用质心算法优化性能",
            isFinal: true
        )
        let chunkPartial = TranscriptChunk(
            source: .mic,
            text: "这是一句未完成的临时草稿",
            isFinal: false
        )

        let meeting = Meeting(
            title: "算法攻坚会",
            transcriptChunks: [chunk1, chunk2, chunkPartial]
        )
        let summary = MeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.matches(searchText: "离线说话人聚类"))
        XCTAssertTrue(summary.matches(searchText: "质心算法"))
        // Partial/non-final chunks are filtered out from searchable text to avoid transient noise
        XCTAssertFalse(summary.matches(searchText: "未完成的临时草稿"))
    }

    func testMultiKeywordSearchRequiresAllTermsToMatch() {
        let meeting = Meeting(
            title: "客户端性能专题",
            transcriptChunks: [
                TranscriptChunk(source: .mic, text: "内存占用降低了百分之三十", isFinal: true)
            ],
            generatedNotes: "首屏加载耗时缩短到 300毫秒"
        )
        let summary = MeetingSummary(meeting: meeting)

        // Both terms match (one in transcript, one in notes)
        XCTAssertTrue(summary.matches(searchText: "内存 300毫秒"))
        XCTAssertTrue(summary.matches(searchText: "性能 缩短"))

        // One term matches, one term does not -> must NOT match
        XCTAssertFalse(summary.matches(searchText: "内存 闪退异常"))
    }

    func testTagSearchWithHashPrefix() {
        let meeting = Meeting(
            title: "技术分享",
            tags: ["技术架构", "SwiftUI"]
        )
        let summary = MeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.matches(searchText: "#技术架构"))
        XCTAssertTrue(summary.matches(searchText: "＃架构")) // supports full-width hash
        XCTAssertTrue(summary.matches(searchText: "#swiftui"))
        XCTAssertFalse(summary.matches(searchText: "#营销"))

        // Bare # matches any meeting that has tags
        XCTAssertTrue(summary.matches(searchText: "#"))

        let meetingNoTags = Meeting(title: "无标签会议")
        let summaryNoTags = MeetingSummary(meeting: meetingNoTags)
        XCTAssertFalse(summaryNoTags.matches(searchText: "#"))
    }

    func testCombinedTagAndKeywordSearch() {
        let meeting = Meeting(
            title: "年度预算汇报",
            generatedNotes: "市场部投入预算已获批准",
            tags: ["财务"]
        )
        let summary = MeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.matches(searchText: "#财务 预算"))
        XCTAssertTrue(summary.matches(searchText: "#财务 批准"))
        XCTAssertFalse(summary.matches(searchText: "#财务 驳回"))
        XCTAssertFalse(summary.matches(searchText: "#人力 预算"))
    }

    func testStructuredExtractionContentIsSearchable() {
        let meeting = Meeting(
            title: "产品需求会",
            followUpTasks: [
                MeetingFollowUpTask(title: "输出原型设计图", kind: .actionItem, owner: "张三")
            ],
            decisions: [
                MeetingDecision(title: "放弃支持旧版协议", owner: "李四")
            ],
            risks: [
                MeetingRisk(title: "第三方服务器不稳定", mitigation: "配置备用镜像节点", owner: "王五")
            ],
            openQuestions: [
                MeetingOpenQuestion(question: "灰度放量比例如何把控", owner: "赵六", nextStep: "周五前评审")
            ]
        )
        let summary = MeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.matches(searchText: "原型设计图"))
        XCTAssertTrue(summary.matches(searchText: "张三"))
        XCTAssertTrue(summary.matches(searchText: "旧版协议"))
        XCTAssertTrue(summary.matches(searchText: "备用镜像节点"))
        XCTAssertTrue(summary.matches(searchText: "灰度放量比例"))
    }

    func testUpdateTitleDoesNotDuplicateSearchableText() {
        let meeting = Meeting(
            title: "原标题",
            generatedNotes: "这是一份会议纪要"
        )
        var summary = MeetingSummary(meeting: meeting)

        summary.updateTitle("第一次修改")
        XCTAssertTrue(summary.matches(searchText: "第一次修改"))

        summary.updateTitle("第二次修改")
        XCTAssertTrue(summary.matches(searchText: "第二次修改"))
        XCTAssertFalse(summary.matches(searchText: "第一次修改"))
        XCTAssertTrue(summary.matches(searchText: "会议纪要"))
    }
}
