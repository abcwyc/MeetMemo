import XCTest
@testable import MeetMemo

final class RecordingSessionAvailabilityTests: XCTestCase {
    func testIdleSessionIsAvailable() {
        XCTAssertFalse(RecordingSessionManager.sessionIsBusy(
            activeMeetingId: nil,
            isRecording: false,
            isStoppingRecording: false,
            isStoppingFromSessionManager: false
        ))
    }

    func testStartingSessionOwnsGlobalSlotBeforeAudioBecomesVisible() {
        XCTAssertTrue(RecordingSessionManager.sessionIsBusy(
            activeMeetingId: UUID(),
            isRecording: false,
            isStoppingRecording: false,
            isStoppingFromSessionManager: false
        ))
    }

    func testFinalizingSessionKeepsGlobalSlotOccupied() {
        XCTAssertTrue(RecordingSessionManager.sessionIsBusy(
            activeMeetingId: UUID(),
            isRecording: false,
            isStoppingRecording: true,
            isStoppingFromSessionManager: true
        ))
    }
}
