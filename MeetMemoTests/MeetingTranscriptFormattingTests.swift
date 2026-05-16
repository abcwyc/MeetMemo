import XCTest
@testable import MeetMemo

final class MeetingTranscriptFormattingTests: XCTestCase {
    func testFormattedTranscriptGroupsSpeakerChunksWithTimeRange() {
        let meeting = Meeting(transcriptChunks: [
            TranscriptChunk(
                source: .mic,
                text: "第一句",
                isFinal: true,
                speakerTag: "speaker-1",
                startTime: 0,
                endTime: 1_000
            ),
            TranscriptChunk(
                source: .mic,
                text: "第二句",
                isFinal: true,
                speakerTag: "speaker-1",
                startTime: 1_000,
                endTime: 2_500
            ),
            TranscriptChunk(
                source: .system,
                text: "对方回复",
                isFinal: true,
                speakerTag: "speaker-2",
                startTime: 3_000,
                endTime: 4_000
            )
        ])

        XCTAssertEqual(
            meeting.formattedTranscript,
            """
            mic · 发言人 A · 00:00 - 00:02: 第一句
            第二句
            online · 发言人 B · 00:03 - 00:04: 对方回复
            """
        )

        XCTAssertEqual(
            meeting.compactTranscript,
            """
            发言人 A: 第一句
            第二句
            发言人 B: 对方回复
            """
        )
    }

    func testDisplayGroupingSplitsSameSpeakerAfterLongGap() {
        let meeting = Meeting(
            title: "Gap grouping",
            transcriptChunks: [
                TranscriptChunk(
                    source: .mic,
                    text: "第一段",
                    isFinal: true,
                    speakerTag: "A",
                    startTime: 1_000,
                    endTime: 2_000
                ),
                TranscriptChunk(
                    source: .mic,
                    text: "第二段",
                    isFinal: true,
                    speakerTag: "A",
                    startTime: 5_500,
                    endTime: 6_000
                )
            ]
        )

        XCTAssertEqual(meeting.transcriptDisplayChunks.map(\.text), ["第一段", "第二段"])
    }

    func testDisplayGroupingDoesNotMergeLowConfidenceWithCanonicalUtterance() {
        let meeting = Meeting(transcriptChunks: [
            TranscriptChunk(
                source: .mic,
                text: "低置信草稿",
                isFinal: true,
                speakerTag: "A",
                startTime: 1_000,
                endTime: 1_000,
                isLowConfidence: true
            ),
            TranscriptChunk(
                source: .mic,
                text: "正式结果",
                isFinal: true,
                speakerTag: "A",
                startTime: 1_100,
                endTime: 2_000
            )
        ])

        XCTAssertEqual(meeting.transcriptDisplayChunks.map(\.text), ["低置信草稿", "正式结果"])
        XCTAssertEqual(meeting.transcriptDisplayChunks.map(\.isLowConfidence), [true, false])
    }

    func testTranscriptDisplayChunksAreSortedByTimeline() {
        let meeting = Meeting(transcriptChunks: [
            TranscriptChunk(
                source: .mic,
                text: "后面的内容",
                isFinal: true,
                speakerTag: "speaker-1",
                startTime: 1_501_000,
                endTime: 1_503_000
            ),
            TranscriptChunk(
                source: .mic,
                text: "开头迟到的内容",
                isFinal: true,
                speakerTag: "speaker-1",
                startTime: 0,
                endTime: 3_000
            ),
            TranscriptChunk(
                source: .mic,
                text: "中间迟到的内容",
                isFinal: true,
                speakerTag: "speaker-1",
                startTime: 1_501_000,
                endTime: 1_501_500
            )
        ])

        XCTAssertEqual(
            meeting.transcriptDisplayChunks.map(\.text),
            [
                "开头迟到的内容",
                """
                中间迟到的内容
                后面的内容
                """
            ]
        )
    }

    func testEndOnlyChunkSortsByItsKnownTimelinePosition() {
        let meeting = Meeting(transcriptChunks: [
            TranscriptChunk(
                source: .mic,
                text: "后面的内容",
                isFinal: true,
                speakerTag: "speaker-2",
                startTime: 3_000,
                endTime: 5_000
            ),
            TranscriptChunk(
                source: .mic,
                text: "开头只有结束时间",
                isFinal: true,
                speakerTag: "speaker-1",
                startTime: nil,
                endTime: 2_000
            )
        ])

        XCTAssertEqual(
            meeting.transcriptDisplayChunks.map(\.text),
            ["开头只有结束时间", "后面的内容"]
        )
    }

    func testDisplayGroupingDoesNotMergeChunkWithMissingStartTime() {
        let meeting = Meeting(transcriptChunks: [
            TranscriptChunk(
                source: .mic,
                text: "第一段",
                isFinal: true,
                speakerTag: "speaker-1",
                startTime: 1_000,
                endTime: 2_000
            ),
            TranscriptChunk(
                source: .mic,
                text: "只有结束时间",
                isFinal: true,
                speakerTag: "speaker-1",
                startTime: nil,
                endTime: 2_500
            )
        ])

        XCTAssertEqual(
            meeting.transcriptDisplayChunks.map(\.text),
            ["第一段", "只有结束时间"]
        )
    }
}
