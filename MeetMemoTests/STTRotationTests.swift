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
            isCorrection: true
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
            isCorrection: false
        )

        let shifted = AudioManager.offsetTranscriptUpdate(update, by: 25 * 60 * 1000)

        XCTAssertNil(shifted.startTime)
        XCTAssertNil(shifted.endTime)
    }
}
