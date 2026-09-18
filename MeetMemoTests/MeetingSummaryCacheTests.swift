import XCTest
@testable import MeetMemo

final class MeetingSummaryCacheTests: XCTestCase {
    func testMatchingFreshSummaryDoesNotRebuildCache() {
        let id = UUID()
        let meetingURL = URL(fileURLWithPath: "/meeting-\(id).json")
        let summaryURL = URL(fileURLWithPath: "/summary-\(id).json")
        let dates = [
            meetingURL: Date(timeIntervalSince1970: 100),
            summaryURL: Date(timeIntervalSince1970: 101),
        ]

        XCTAssertFalse(LocalStorageManager.summaryCacheNeedsRefresh(
            meetingFilesById: [id: meetingURL],
            summaryFilesById: [id: summaryURL],
            decodedSummaryIds: [id],
            hasInvalidSummaries: false,
            fileModificationDate: { dates[$0] }
        ))
    }

    func testNewerMeetingFileRebuildsCache() {
        let id = UUID()
        let meetingURL = URL(fileURLWithPath: "/meeting-\(id).json")
        let summaryURL = URL(fileURLWithPath: "/summary-\(id).json")
        let dates = [
            meetingURL: Date(timeIntervalSince1970: 102),
            summaryURL: Date(timeIntervalSince1970: 101),
        ]

        XCTAssertTrue(LocalStorageManager.summaryCacheNeedsRefresh(
            meetingFilesById: [id: meetingURL],
            summaryFilesById: [id: summaryURL],
            decodedSummaryIds: [id],
            hasInvalidSummaries: false,
            fileModificationDate: { dates[$0] }
        ))
    }

    func testMissingOrOrphanSummaryRebuildsCache() {
        let meetingId = UUID()
        let orphanId = UUID()

        XCTAssertTrue(LocalStorageManager.summaryCacheNeedsRefresh(
            meetingFilesById: [meetingId: URL(fileURLWithPath: "/meeting.json")],
            summaryFilesById: [orphanId: URL(fileURLWithPath: "/orphan.json")],
            decodedSummaryIds: [orphanId],
            hasInvalidSummaries: false
        ))
    }

    func testInvalidSummaryRebuildsCache() {
        XCTAssertTrue(LocalStorageManager.summaryCacheNeedsRefresh(
            meetingFilesById: [:],
            summaryFilesById: [:],
            decodedSummaryIds: [],
            hasInvalidSummaries: true
        ))
    }
}
