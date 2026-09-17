import AppKit

/// Typography shared by the two surfaces that render meeting notes:
/// `RenderedNotesView` (native, shown while AI generation streams in) and
/// `MarkdownWebEditorView` (WKWebView-hosted, shown once generation settles).
///
/// They have to agree on at least the body size, because the app swaps one
/// for the other the moment generation finishes — if the sizes differ, the
/// text visibly resizes under the user at that exact moment.
enum MeetingNotesTypography {
    /// Compact reading size shared by the native and web renderers.
    static let bodyFontSize: CGFloat = 13

    /// Left/right gutter. The native renderer applies it as
    /// `textContainerInset`; the web editor as `padding-inline` (see
    /// `web/markdown-editor/src/overrides.css`).
    static let contentInset: CGFloat = 24

    static let webLineHeight: CGFloat = 1.5

    static func headingSize(for level: Int, theme: MarkdownTheme = .github) -> CGFloat {
        let scale: CGFloat
        switch theme {
        case .meetMemo:
            scale = [1: 1.75, 2: 1.35, 3: 1.15][level] ?? 1
        case .github:
            scale = [1: 2, 2: 1.5, 3: 1.25][level] ?? 1
        case .bear:
            scale = [1: 1.9, 2: 1.4, 3: 1.18][level] ?? 1
        case .typora:
            scale = [1: 3, 2: 1.5, 3: 1.17][level] ?? 1
        case .sspai:
            scale = [1: 2.2, 2: 1.4, 3: 1.2][level] ?? 1.1
        }
        return bodyFontSize * scale
    }

    static func headingWeight(for level: Int, theme: MarkdownTheme = .github) -> NSFont.Weight {
        switch theme {
        case .typora: return .regular
        case .sspai: return .bold
        case .meetMemo, .github, .bear: return .semibold
        }
    }
}
