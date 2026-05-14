import XCTest
@testable import MeetMemo

final class TranscriptUpdateAccumulatorTests: XCTestCase {
    func testUpdatedFinalWithoutExistingFinalIsPreserved() {
        var accumulator = TranscriptUpdateAccumulator()

        accumulator.apply(
            STTTranscriptUpdate(
                text: "draft sentence",
                isFinal: false,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 2_000,
                isCorrection: false
            ),
            source: .mic
        )

        accumulator.apply(
            STTTranscriptUpdate(
                text: "final sentence",
                isFinal: true,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 2_000,
                isCorrection: true
            ),
            source: .mic
        )

        XCTAssertEqual(accumulator.chunks.count, 1)
        XCTAssertEqual(accumulator.chunks.first?.text, "final sentence")
        XCTAssertEqual(accumulator.chunks.first?.isFinal, true)
    }

    func testMultipleInterimsAreTrackedByTimeRange() {
        var accumulator = TranscriptUpdateAccumulator()

        accumulator.apply(
            STTTranscriptUpdate(
                text: "first draft",
                isFinal: false,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 2_000,
                isCorrection: false
            ),
            source: .mic
        )
        accumulator.apply(
            STTTranscriptUpdate(
                text: "second draft",
                isFinal: false,
                speakerTag: "A",
                speakerId: 1,
                startTime: 2_000,
                endTime: 3_000,
                isCorrection: false
            ),
            source: .mic
        )
        accumulator.apply(
            STTTranscriptUpdate(
                text: "first final",
                isFinal: true,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 2_000,
                isCorrection: true
            ),
            source: .mic
        )

        XCTAssertEqual(accumulator.chunks.map(\.text), ["first final", "second draft"])
        XCTAssertEqual(accumulator.chunks.filter(\.isFinal).map(\.text), ["first final"])
        XCTAssertEqual(accumulator.chunks.filter { !$0.isFinal }.map(\.text), ["second draft"])
    }

    func testGrowingInterimReplacesPreviousDraft() {
        var accumulator = TranscriptUpdateAccumulator()

        accumulator.apply(
            STTTranscriptUpdate(
                text: "遇到了很多的",
                isFinal: false,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 2_000,
                isCorrection: false
            ),
            source: .mic
        )
        accumulator.apply(
            STTTranscriptUpdate(
                text: "遇到了很多的坑嘛？这个坑也是",
                isFinal: false,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 3_000,
                isCorrection: false
            ),
            source: .mic
        )

        XCTAssertEqual(accumulator.chunks.count, 1)
        XCTAssertEqual(accumulator.chunks[0].text, "遇到了很多的坑嘛？这个坑也是")
        XCTAssertFalse(accumulator.chunks[0].isFinal)
    }

    func testGrowingFinalReplacesPreviousIncrementalFinals() {
        var accumulator = TranscriptUpdateAccumulator()

        accumulator.apply(
            STTTranscriptUpdate(
                text: "嗯，win",
                isFinal: true,
                speakerTag: nil,
                speakerId: nil,
                startTime: nil,
                endTime: nil,
                isCorrection: false
            ),
            source: .mic
        )
        accumulator.apply(
            STTTranscriptUpdate(
                text: "嗯，win 8 间的这种客户形式不太一样，它是一个群聊的多人对话的多角色",
                isFinal: true,
                speakerTag: "A",
                speakerId: 1,
                startTime: nil,
                endTime: nil,
                isCorrection: false
            ),
            source: .mic
        )

        XCTAssertEqual(accumulator.chunks.count, 1)
        XCTAssertEqual(accumulator.chunks[0].text, "嗯，win 8 间的这种客户形式不太一样，它是一个群聊的多人对话的多角色")
        XCTAssertEqual(accumulator.chunks[0].speakerTag, "A")
        XCTAssertTrue(accumulator.chunks[0].isFinal)
    }

    func testGrowingFinalWithInsertedPunctuationReplacesPreviousFinals() {
        var accumulator = TranscriptUpdateAccumulator()

        accumulator.apply(
            STTTranscriptUpdate(
                text: "但凡我们，呃看清楚，想清楚事情哪些重要，哪些不重要，其实这个过程中即使",
                isFinal: true,
                speakerTag: nil,
                speakerId: nil,
                startTime: 8_000,
                endTime: nil,
                isCorrection: false
            ),
            source: .mic
        )

        accumulator.apply(
            STTTranscriptUpdate(
                text: "但凡我们，呃看清楚，想清楚事情哪些重要，哪些不重要，其实这个过程中，即使这个过程失败了，我觉得这个信念感是比较重要的",
                isFinal: true,
                speakerTag: nil,
                speakerId: nil,
                startTime: 16_000,
                endTime: nil,
                isCorrection: false
            ),
            source: .mic
        )

        accumulator.apply(
            STTTranscriptUpdate(
                text: "但凡我们，呃看清楚，想清楚事情哪些重要，哪些不重要，其实这个过程中，即使这个过程失败了，我觉得这个信念感是比较重要的，就是说我们直觉上哪些事情一定能做成这个事情？呃呃这个呃包括个人",
                isFinal: true,
                speakerTag: nil,
                speakerId: nil,
                startTime: 19_000,
                endTime: nil,
                isCorrection: false
            ),
            source: .mic
        )

        XCTAssertEqual(accumulator.chunks.count, 1)
        XCTAssertEqual(
            accumulator.chunks[0].text,
            "但凡我们，呃看清楚，想清楚事情哪些重要，哪些不重要，其实这个过程中，即使这个过程失败了，我觉得这个信念感是比较重要的，就是说我们直觉上哪些事情一定能做成这个事情？呃呃这个呃包括个人"
        )
    }

    func testCorrectionUpdatesExistingFinalInPlace() {
        var accumulator = TranscriptUpdateAccumulator()

        accumulator.apply(
            STTTranscriptUpdate(
                text: "original final",
                isFinal: true,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 2_000,
                isCorrection: false
            ),
            source: .mic
        )
        let originalId = accumulator.chunks[0].id

        accumulator.apply(
            STTTranscriptUpdate(
                text: "corrected final",
                isFinal: true,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 2_000,
                isCorrection: true
            ),
            source: .mic
        )

        XCTAssertEqual(accumulator.chunks.count, 1)
        XCTAssertEqual(accumulator.chunks[0].id, originalId)
        XCTAssertEqual(accumulator.chunks[0].text, "corrected final")
    }
}
