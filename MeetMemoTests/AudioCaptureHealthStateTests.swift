import XCTest
@testable import MeetMemo

final class AudioCaptureHealthStateTests: XCTestCase {
    func testReportsStallWhenNoMicBufferArrivesBeforeTimeout() {
        var state = AudioCaptureHealthState()
        state.begin(at: 100)

        XCTAssertFalse(state.isMicStalled(at: 104.9, timeout: 5))
        XCTAssertTrue(state.isMicStalled(at: 105, timeout: 5))
    }

    func testMicBufferRefreshesLivenessDeadline() {
        var state = AudioCaptureHealthState()
        state.begin(at: 100)
        state.noteMicBuffer(at: 104)

        XCTAssertFalse(state.isMicStalled(at: 108.9, timeout: 5))
        XCTAssertTrue(state.isMicStalled(at: 109, timeout: 5))
    }

    func testResetDisablesStallDetection() {
        var state = AudioCaptureHealthState()
        state.begin(at: 100)
        state.reset()

        XCTAssertFalse(state.isMicStalled(at: 200, timeout: 5))
    }
}
