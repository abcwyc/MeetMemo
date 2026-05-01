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
    }
}

