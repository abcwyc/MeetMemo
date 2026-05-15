import XCTest
@testable import MeetMemo

final class TranscriptFixtureReplayTests: XCTestCase {
    func testFixtureReplayPreservesGoldenTranscriptOrder() {
        let fixture: [STTTranscriptUpdate] = [
            STTTranscriptUpdate(
                text: "第一句",
                isFinal: true,
                speakerTag: "A",
                speakerId: 1,
                startTime: 1_000,
                endTime: 2_000,
                isCorrection: false
            ),
            STTTranscriptUpdate(
                text: "第二句",
                isFinal: true,
                speakerTag: "B",
                speakerId: 2,
                startTime: 2_100,
                endTime: 3_000,
                isCorrection: false
            )
        ]

        var accumulator = TranscriptUpdateAccumulator()
        fixture.forEach { accumulator.apply($0, source: .mic) }

        XCTAssertEqual(accumulator.chunks.map(\.text), ["第一句", "第二句"])
    }
}
