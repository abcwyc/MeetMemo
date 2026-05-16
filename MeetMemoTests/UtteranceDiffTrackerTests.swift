import XCTest
@testable import MeetMemo

final class UtteranceDiffTrackerTests: XCTestCase {
    func testDiffEmitsOnlyNewAndChangedUtterances() throws {
        var tracker = UtteranceDiffTracker()

        let first = try decodeUtterances("""
        [
          {"text":"hello","definite":true,"startTime":0,"endTime":1000,"speaker_id":"1"}
        ]
        """)

        let initialChanges = tracker.diff(first)
        XCTAssertEqual(initialChanges.count, 1)

        let unchangedChanges = tracker.diff(first)
        XCTAssertTrue(unchangedChanges.isEmpty)

        let updated = try decodeUtterances("""
        [
          {"text":"hello world","definite":true,"startTime":0,"endTime":1000,"speaker_id":"1"},
          {"text":"next","definite":false,"startTime":1000,"endTime":1500,"speaker_id":"2"}
        ]
        """)

        let changed = tracker.diff(updated)
        XCTAssertEqual(changed.count, 2)
    }

    func testDoubaoUtteranceDecodesSnakeCaseTimes() throws {
        let utterances = try decodeUtterances("""
        [
          {"text":"hello","definite":true,"start_time":120,"end_time":980,"speaker_id":"1"}
        ]
        """)

        XCTAssertEqual(utterances.first?.startTime, 120)
        XCTAssertEqual(utterances.first?.endTime, 980)
    }

    func testUntimedUtterancesUseOrdinalIdentityWithoutColliding() throws {
        var tracker = UtteranceDiffTracker()

        let first = try decodeUtterances("""
        [
          {"text":"first draft","definite":false,"speaker_id":"1"},
          {"text":"second draft","definite":false,"speaker_id":"1"}
        ]
        """)
        XCTAssertEqual(tracker.diff(first).count, 2)

        let updated = try decodeUtterances("""
        [
          {"text":"first final","definite":true,"speaker_id":"1"},
          {"text":"second final","definite":true,"speaker_id":"1"}
        ]
        """)
        XCTAssertEqual(tracker.diff(updated).count, 2)
    }

    private func decodeUtterances(_ json: String) throws -> [DoubaoUtterance] {
        try JSONDecoder().decode([DoubaoUtterance].self, from: Data(json.utf8))
    }
}
