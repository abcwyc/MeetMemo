import XCTest
@testable import MeetMemo

final class STTRotationTests: XCTestCase {
    func testTranscriptUpdateTimeOffsetKeepsRotatedSessionsOnMeetingTimeline() {
        let update = STTTranscriptUpdate(
            text: "second segment",
            isFinal: true,
            speakerTag: "speaker A",
            speakerId: 1,
            startTime: 1_000,
            endTime: 2_500,
            isCorrection: true,
            isLowConfidence: false
        )

        let shifted = AudioManager.offsetTranscriptUpdate(update, by: 25 * 60 * 1000)

        XCTAssertEqual(shifted.text, update.text)
        XCTAssertEqual(shifted.isFinal, update.isFinal)
        XCTAssertEqual(shifted.speakerTag, update.speakerTag)
        XCTAssertEqual(shifted.speakerId, update.speakerId)
        XCTAssertEqual(shifted.startTime, 1_501_000)
        XCTAssertEqual(shifted.endTime, 1_502_500)
        XCTAssertEqual(shifted.isCorrection, update.isCorrection)
    }

    func testTranscriptUpdateTimeOffsetLeavesMissingTimesUnchanged() {
        let update = STTTranscriptUpdate(
            text: "untimed",
            isFinal: false,
            speakerTag: nil,
            speakerId: nil,
            startTime: nil,
            endTime: nil,
            isCorrection: false,
            isLowConfidence: false
        )

        let shifted = AudioManager.offsetTranscriptUpdate(update, by: 25 * 60 * 1000)

        XCTAssertNil(shifted.startTime)
        XCTAssertNil(shifted.endTime)
    }

    func testMaximumTranscriptEndTimeUsesExistingMeetingTimeline() {
        let chunks = [
            TranscriptChunk(source: .mic, text: "first", isFinal: true, startTime: 1_000, endTime: 2_000),
            TranscriptChunk(source: .system, text: "second", isFinal: true, startTime: 4_000, endTime: nil),
            TranscriptChunk(source: .mic, text: "third", isFinal: true, startTime: 5_000, endTime: 8_500)
        ]

        XCTAssertEqual(AudioManager.maximumTranscriptEndTime(in: chunks), 8_500)
    }

    func testPositionedLowConfidenceUpdateAnchorsMissingTiming() {
        let update = STTTranscriptUpdate(
            text: "fallback",
            isFinal: true,
            speakerTag: nil,
            speakerId: nil,
            startTime: nil,
            endTime: nil,
            isCorrection: false,
            isLowConfidence: true
        )

        let positioned = AudioManager.positionedLowConfidenceUpdate(update, fallbackMilliseconds: 12_345)

        XCTAssertEqual(positioned.startTime, 12_345)
        XCTAssertEqual(positioned.endTime, 12_345)
        XCTAssertTrue(positioned.isLowConfidence)
        XCTAssertEqual(positioned.text, update.text)
    }

    func testPositionedLowConfidenceUpdateLeavesNormalUpdateUnchanged() {
        let update = STTTranscriptUpdate(
            text: "normal",
            isFinal: true,
            speakerTag: "A",
            speakerId: 1,
            startTime: 1_000,
            endTime: 2_000,
            isCorrection: false,
            isLowConfidence: false
        )

        let positioned = AudioManager.positionedLowConfidenceUpdate(update, fallbackMilliseconds: 99_999)

        XCTAssertEqual(positioned.startTime, 1_000)
        XCTAssertEqual(positioned.endTime, 2_000)
        XCTAssertFalse(positioned.isLowConfidence)
    }

    func testPositionedLowConfidenceUpdatePreservesProviderTiming() {
        // When a low-confidence update happens to carry timing, do not overwrite it.
        let update = STTTranscriptUpdate(
            text: "fallback with timing",
            isFinal: true,
            speakerTag: nil,
            speakerId: nil,
            startTime: 5_000,
            endTime: 5_500,
            isCorrection: false,
            isLowConfidence: true
        )

        let positioned = AudioManager.positionedLowConfidenceUpdate(update, fallbackMilliseconds: 99_999)

        XCTAssertEqual(positioned.startTime, 5_000)
        XCTAssertEqual(positioned.endTime, 5_500)
    }

    func testTranscriptChunkHashIgnoresArrivalUptime() {
        let id = UUID()
        let timestamp = Date()
        let chunkA = TranscriptChunk(
            id: id,
            timestamp: timestamp,
            source: .mic,
            text: "hello",
            isFinal: true,
            speakerTag: "A",
            speakerId: 1,
            startTime: 1_000,
            endTime: 2_000,
            isLowConfidence: false,
            arrivalUptimeMilliseconds: 100
        )
        let chunkB = TranscriptChunk(
            id: id,
            timestamp: timestamp,
            source: .mic,
            text: "hello",
            isFinal: true,
            speakerTag: "A",
            speakerId: 1,
            startTime: 1_000,
            endTime: 2_000,
            isLowConfidence: false,
            arrivalUptimeMilliseconds: 999_999
        )

        XCTAssertEqual(chunkA, chunkB)
        XCTAssertEqual(chunkA.hashValue, chunkB.hashValue)
    }
}
