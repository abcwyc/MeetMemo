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
            "## First\n\n# Agenda\n\nOpening\n\n---\n\n## Second\n\n## Risks\n\nSchedule"
        )
    }

    func testEnsureUnifiedContextRecordDropsTitlesTheAppStampedItself() {
        var meeting = Meeting(contextItems: [
            MeetingContextItem(kind: .text, title: "手动补充", extractedText: "A"),
            MeetingContextItem(kind: .text, title: "Manual Context", extractedText: "B")
        ])

        meeting.ensureUnifiedContextRecord(defaultTitle: "记录")

        XCTAssertEqual(meeting.contextItems[0].extractedText, "A\n\n---\n\nB")
    }

    func testEnsureUnifiedContextRecordKeepsAnAuthoredNameOnASingleCard() {
        var meeting = Meeting(contextItems: [
            MeetingContextItem(kind: .text, title: "客户背景", extractedText: "Keep me")
        ])

        meeting.ensureUnifiedContextRecord(defaultTitle: "记录")

        XCTAssertEqual(meeting.contextItems[0].extractedText, "## 客户背景\n\nKeep me")
    }

    func testEnsureUnifiedContextRecordLeavesAnUnnamedCardUntouched() {
        var meeting = Meeting(contextItems: [
            MeetingContextItem(kind: .text, title: "记录", extractedText: "Draft\n\n")
        ])

        meeting.ensureUnifiedContextRecord(defaultTitle: "记录")

        XCTAssertEqual(meeting.contextItems[0].extractedText, "Draft\n\n")
    }

    /// The workspace re-runs this on every visit, so a promoted name must not
    /// stack a fresh heading onto the document each time.
    func testEnsureUnifiedContextRecordIsIdempotent() {
        var meeting = Meeting(contextItems: [
            MeetingContextItem(kind: .text, title: "Existing", extractedText: "Keep me")
        ])

        let firstId = meeting.ensureUnifiedContextRecord(defaultTitle: "记录")
        let secondId = meeting.ensureUnifiedContextRecord(defaultTitle: "记录")

        XCTAssertEqual(firstId, secondId)
        XCTAssertEqual(meeting.contextItems.count, 1)
        XCTAssertEqual(meeting.contextItems[0].extractedText, "## Existing\n\nKeep me")
    }

    /// Switching the app language changes `defaultTitle`, which must not make
    /// an already-promoted record look like it carries a user-authored name.
    func testEnsureUnifiedContextRecordIsIdempotentAcrossALanguageSwitch() {
        var meeting = Meeting(contextItems: [
            MeetingContextItem(kind: .text, title: "Existing", extractedText: "Keep me")
        ])

        meeting.ensureUnifiedContextRecord(defaultTitle: "记录")
        meeting.ensureUnifiedContextRecord(defaultTitle: "Note")

        XCTAssertEqual(meeting.contextItems[0].extractedText, "## Existing\n\nKeep me")
    }
}
