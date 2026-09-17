import Foundation

/// A document as last handed to — or last reported by — the embedded editor.
struct MarkdownEditorDocumentState: Equatable {
    let documentId: String
    let markdown: String
    let readOnly: Bool
}

/// The last text change reported by a particular mounted editor document.
/// Scoping the text to the document identity is essential: two meetings may
/// legitimately contain identical Markdown, and a previous meeting's edit
/// must never suppress a later disk-loaded document.
struct MarkdownEditorEmission: Equatable {
    let documentId: String
    let markdown: String
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
        lastEmittedByEditor: MarkdownEditorEmission?
    ) -> MarkdownEditorSyncAction {
        guard let lastPushed else {
            return .push(remount: true)
        }

        if incoming.documentId != lastPushed.documentId {
            return .push(remount: true)
        }

        // Content that changed behind the editor's back (for example a
        // regenerated note replacing the current document). The meeting
        // list preloads ordinary selections now, but direct/fallback callers
        // may still deliver content after identity has settled. Anything the
        // editor told us about is excluded, since that is the user typing,
        // not the app substituting a document.
        let isCurrentDocumentEditEcho = lastEmittedByEditor?.documentId == incoming.documentId
            && lastEmittedByEditor?.markdown == incoming.markdown
        if incoming.markdown != lastPushed.markdown, !isCurrentDocumentEditEcho {
            return .push(remount: true)
        }

        if incoming.readOnly != lastPushed.readOnly {
            return .push(remount: false)
        }

        return .ignore
    }
}
