import XCTest
@testable import MeetMemo

final class MeetingContextWorkspaceTests: XCTestCase {
    func testEnsureUnifiedContextRecordCreatesAnEmptyRecord() {
        var meeting = Meeting()

        let id = meeting.ensureUnifiedContextRecord(defaultTitle: "记录")

        XCTAssertEqual(meeting.contextItems.count, 1)
        XCTAssertEqual(meeting.contextItems.first?.id, id)
        XCTAssertEqual(meeting.contextItems.first?.kind, .text)
        XCTAssertEqual(meeting.contextItems.first?.title, "记录")
        XCTAssertEqual(meeting.contextItems.first?.extractedText, "")
    }

    func testEnsureUnifiedContextRecordMergesLegacyTextCardsAndKeepsAttachments() {
        let firstText = MeetingContextItem(
            kind: .text,
            title: "First",
            extractedText: "# Agenda\n\nOpening"
        )
        let attachment = MeetingContextItem(
            kind: .file,
            title: "brief.txt",
            source: "/tmp/brief.txt",
            extractedText: "Background",
            extractionStatus: .succeeded
        )
        let secondText = MeetingContextItem(
            kind: .text,
            title: "Second",
            extractedText: "## Risks\n\nSchedule"
        )
        var meeting = Meeting(contextItems: [firstText, attachment, secondText])

        let id = meeting.ensureUnifiedContextRecord(defaultTitle: "记录")

        XCTAssertEqual(id, firstText.id)
        XCTAssertEqual(meeting.contextItems.filter { $0.kind == .text }.count, 1)
        XCTAssertEqual(meeting.contextItems.filter { $0.kind == .file }, [attachment])
        XCTAssertEqual(
            meeting.contextItems.first(where: { $0.kind == .text })?.extractedText,
            "# Agenda\n\nOpening\n\n---\n\n## Risks\n\nSchedule"
        )
    }

    func testEnsureUnifiedContextRecordIsIdempotent() {
        var meeting = Meeting(contextItems: [
            MeetingContextItem(kind: .text, title: "Existing", extractedText: "Keep me")
        ])

        let firstId = meeting.ensureUnifiedContextRecord(defaultTitle: "记录")
        let secondId = meeting.ensureUnifiedContextRecord(defaultTitle: "记录")

        XCTAssertEqual(firstId, secondId)
        XCTAssertEqual(meeting.contextItems.count, 1)
        XCTAssertEqual(meeting.contextItems[0].extractedText, "Keep me")
    }
}
