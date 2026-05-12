import XCTest
@testable import MeetMemo

final class AudioRecordingStateMachineTests: XCTestCase {
    func testRecordingLifecycleKeepsSessionIdentityAndVisibility() {
        let sessionID = UUID()
        var machine = AudioRecordingStateMachine()

        XCTAssertEqual(machine.state, .idle)
        XCTAssertFalse(machine.state.isRecordingVisible)

        machine.start(sessionID: sessionID)
        XCTAssertEqual(machine.state, .starting(sessionID))
        XCTAssertTrue(machine.state.isActiveSession(sessionID))
        XCTAssertFalse(machine.state.isRecordingVisible)

        machine.markRecording(sessionID: sessionID)
        XCTAssertEqual(machine.state, .recording(sessionID))
        XCTAssertTrue(machine.state.isRecordingVisible)

        machine.stop(sessionID: sessionID)
        XCTAssertEqual(machine.state, .stopping(sessionID))
        XCTAssertFalse(machine.state.isActiveSession(sessionID))
        XCTAssertFalse(machine.state.isRecordingVisible)

        machine.reset()
        XCTAssertEqual(machine.state, .idle)
    }

    func testMismatchedSessionCannotPromoteState() {
        let activeSessionID = UUID()
        let staleSessionID = UUID()
        var machine = AudioRecordingStateMachine()

        machine.start(sessionID: activeSessionID)
        machine.markRecording(sessionID: staleSessionID)

        XCTAssertEqual(machine.state, .starting(activeSessionID))
        XCTAssertTrue(machine.state.isActiveSession(activeSessionID))
        XCTAssertFalse(machine.state.isActiveSession(staleSessionID))
    }
}
