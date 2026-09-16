import XCTest
@testable import MeetMemo

final class MarkdownEditorSyncPolicyTests: XCTestCase {
    private func state(_ id: String, _ markdown: String, readOnly: Bool = false) -> MarkdownEditorDocumentState {
        MarkdownEditorDocumentState(documentId: id, markdown: markdown, readOnly: readOnly)
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

    /// The blank-pane bug: selecting a meeting hands the detail view a
    /// placeholder with empty notes, and the real content is read from disk
    /// afterwards — arriving under a documentId that has already settled.
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
            lastEmittedByEditor: typed
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
            lastEmittedByEditor: "# Notes"
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
            lastEmittedByEditor: text
        )
        XCTAssertEqual(action, .push(remount: true))
    }
}
