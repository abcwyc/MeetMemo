import AppKit

/// Typography shared by the two surfaces that render meeting notes:
/// `RenderedNotesView` (native, shown while AI generation streams in) and
/// `MarkdownWebEditorView` (WKWebView-hosted, shown once generation settles).
///
/// They have to agree on at least the body size, because the app swaps one
/// for the other the moment generation finishes — if the sizes differ, the
/// text visibly resizes under the user at that exact moment.
enum MeetingNotesTypography {
    /// Matches the app's body text elsewhere (13pt is the size used across
    /// MeetingListView, transcript rows, etc.).
    static let bodyFontSize: CGFloat = 13

    /// Left/right gutter. The native renderer applies it as
    /// `textContainerInset`; the web editor as `padding-inline` (see
    /// `web/markdown-editor/src/overrides.css`).
    static let contentInset: CGFloat = 16

    /// The web editing surface runs slightly looser than the native
    /// renderer's ~1.27 (`lineSpacing: 1` on 13pt). Deliberate: a surface
    /// you type into benefits from more air than one you only read, and
    /// CodeMirror line boxes read tighter than AppKit's at the same ratio.
    static let webLineHeight: CGFloat = 1.5

    static func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        case 3: return 15
        default: return 14
        }
    }

    static func headingWeight(for level: Int) -> NSFont.Weight {
        switch level {
        case 1, 2: return .semibold
        default: return .medium
        }
    }
}
