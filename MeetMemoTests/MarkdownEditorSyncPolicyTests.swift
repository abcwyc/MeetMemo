import XCTest
@testable import MeetMemo

final class MarkdownEditorSyncPolicyTests: XCTestCase {
    private func state(_ id: String, _ markdown: String, readOnly: Bool = false) -> MarkdownEditorDocumentState {
        MarkdownEditorDocumentState(documentId: id, markdown: markdown, readOnly: readOnly)
    }

    private func emission(_ id: String, _ markdown: String) -> MarkdownEditorEmission {
        MarkdownEditorEmission(documentId: id, markdown: markdown)
    }

    func testFirstSyncMountsTheDocument() {
        let action = MarkdownEditorSyncPolicy.action(
            for: state("a-0", "# Notes"),
            lastPushed: nil,
            lastEmittedByEditor: nil
        )
        XCTAssertEqual(action, .push(remount: true))
    }

    func testSwitchingDocumentsRemounts() {
        let action = MarkdownEditorSyncPolicy.action(
            for: state("b-1", "# Other meeting"),
            lastPushed: state("a-0", "# Notes"),
            lastEmittedByEditor: nil
        )
        XCTAssertEqual(action, .push(remount: true))
    }

    /// Regression coverage for fallback/external loads that deliver content
    /// after the document identity has already settled.
    func testContentArrivingAfterTheDocumentIdSettledRemounts() {
        let action = MarkdownEditorSyncPolicy.action(
            for: state("b-1", "# Real content loaded from disk"),
            lastPushed: state("b-1", ""),
            lastEmittedByEditor: nil
        )
        XCTAssertEqual(action, .push(remount: true))
    }

    /// The reason the policy can't simply react to any content change: the
    /// user's own keystrokes come back through the binding, and remounting
    /// on those would drop the caret mid-word.
    func testEditorsOwnEditEchoingBackIsIgnored() {
        let typed = "# Notes\nsomething the user just typed"
        let action = MarkdownEditorSyncPolicy.action(
            for: state("a-0", typed),
            lastPushed: state("a-0", "# Notes"),
            lastEmittedByEditor: emission("a-0", typed)
        )
        XCTAssertEqual(action, .ignore)
    }

    func testReadOnlyFlipReconfiguresWithoutRemounting() {
        let action = MarkdownEditorSyncPolicy.action(
            for: state("a-0", "# Notes", readOnly: true),
            lastPushed: state("a-0", "# Notes", readOnly: false),
            lastEmittedByEditor: nil
        )
        XCTAssertEqual(action, .push(remount: false))
    }

    func testUnchangedInputIsIgnored() {
        let action = MarkdownEditorSyncPolicy.action(
            for: state("a-0", "# Notes"),
            lastPushed: state("a-0", "# Notes"),
            lastEmittedByEditor: emission("a-0", "# Notes")
        )
        XCTAssertEqual(action, .ignore)
    }

    /// Content substitution outranks a simultaneous readOnly flip: showing
    /// the right document matters more than preserving caret position.
    func testExternalContentChangeWinsOverSimultaneousReadOnlyFlip() {
        let action = MarkdownEditorSyncPolicy.action(
            for: state("a-0", "# Replaced", readOnly: true),
            lastPushed: state("a-0", "# Notes", readOnly: false),
            lastEmittedByEditor: nil
        )
        XCTAssertEqual(action, .push(remount: true))
    }

    /// A regenerated document can legitimately arrive with content the user
    /// happened to have typed earlier; the documentId change is what makes
    /// it unambiguous.
    func testDocumentIdChangeRemountsEvenWhenContentMatchesTheEditorsLastEdit() {
        let text = "# Notes"
        let action = MarkdownEditorSyncPolicy.action(
            for: state("a-1", text),
            lastPushed: state("a-0", text),
            lastEmittedByEditor: emission("a-0", text)
        )
        XCTAssertEqual(action, .push(remount: true))
    }

    /// Regression: edit A, switch to B, then revisit A. The revisit gets a
    /// fresh document revision and initially mounts an empty summary
    /// placeholder. When A's real content arrives from disk it must not be
    /// mistaken for the previous A editor instance echoing its own edit.
    func testRevisitingEditedDocumentDoesNotSuppressDiskLoadedContent() {
        let edited = "# Notes\nEdited content"
        let action = MarkdownEditorSyncPolicy.action(
            for: state("a-2", edited),
            lastPushed: state("a-2", ""),
            lastEmittedByEditor: emission("a-0", edited)
        )
        XCTAssertEqual(action, .push(remount: true))
    }
}
