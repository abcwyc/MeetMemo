import Foundation

/// A document as last handed to — or last reported by — the embedded editor.
struct MarkdownEditorDocumentState: Equatable {
    let documentId: String
    let markdown: String
    let readOnly: Bool
}

enum MarkdownEditorSyncAction: Equatable {
    /// Nothing the editor needs to hear about. Most importantly this covers
    /// the user's own keystroke echoing back through the SwiftUI binding:
    /// reacting to that would remount the editor mid-word.
    case ignore

    /// Send the document to the JS side. `remount` distinguishes the two
    /// things that can follow: tearing the CodeMirror view down and
    /// rebuilding it on new content (which costs caret/scroll/undo), versus
    /// reconfiguring the live view in place, which doesn't.
    case push(remount: Bool)
}

/// Decides what a change to `MarkdownWebEditorView`'s inputs means for the
/// already-mounted editor.
///
/// Split out from the coordinator because it is the whole substance of the
/// "blank notes pane" class of bug, and it's worth being able to test
/// directly: the failure mode is invisible (no crash, no error — just an
/// editor quietly showing the wrong document) and its trigger is a race
/// against an async disk read, which is miserable to reproduce by hand.
enum MarkdownEditorSyncPolicy {
    static func action(
        for incoming: MarkdownEditorDocumentState,
        lastPushed: MarkdownEditorDocumentState?,
        lastEmittedByEditor: String?
    ) -> MarkdownEditorSyncAction {
        guard let lastPushed else {
            return .push(remount: true)
        }

        if incoming.documentId != lastPushed.documentId {
            return .push(remount: true)
        }

        // Content that changed behind the editor's back. Selecting a meeting
        // does exactly this: the detail view first gets a placeholder with
        // empty notes, and the real content arrives from disk a moment later
        // (MeetingViewModel.loadFullMeetingIfNeeded) — by which point the
        // documentId has already settled, so document identity alone can't
        // see it. Anything the editor told us about is excluded, since that
        // is the user typing, not the app substituting a document.
        if incoming.markdown != lastPushed.markdown, incoming.markdown != lastEmittedByEditor {
            return .push(remount: true)
        }

        if incoming.readOnly != lastPushed.readOnly {
            return .push(remount: false)
        }

        return .ignore
    }
}
