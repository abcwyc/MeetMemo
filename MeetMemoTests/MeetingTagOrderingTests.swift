import XCTest
@testable import MeetMemo

@MainActor
final class MeetingTagOrderingTests: XCTestCase {
    func testTagsSortByFrequencyThenNameRegardlessOfMeetingOrder() {
        let meetings = [
            MeetingSummary(meeting: Meeting(title: "One", tags: ["Gamma", "Alpha"])),
            MeetingSummary(meeting: Meeting(title: "Two", tags: ["Beta"])),
            MeetingSummary(meeting: Meeting(title: "Three", tags: ["Gamma"])),
        ]

        let expected = ["Gamma", "Alpha", "Beta"]

        XCTAssertEqual(MeetingListViewModel.sortedTags(in: meetings), expected)
        XCTAssertEqual(MeetingListViewModel.sortedTags(in: Array(meetings.reversed())), expected)
    }
}
