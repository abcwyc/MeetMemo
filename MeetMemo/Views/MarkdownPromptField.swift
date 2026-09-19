import SwiftUI

/// The meeting-notes markdown editor framed as a form field: soft card
/// background, hairline border, rounded corners, and a placeholder overlay
/// while empty — the same visual treatment as the per-meeting context editor.
///
/// Settings prompts (user profile, system prompt) and template prompts reuse
/// this so every long-form text surface in the app reads and edits through
/// the same WYSIWYG surface instead of a plain `TextEditor`.
struct MarkdownPromptField: View {
    @Binding var text: String
    /// Stable per-document identity; change only on genuine document
    /// boundaries — never per keystroke (see `MarkdownWebEditorView`).
    let documentId: String
    var placeholder: String = ""
    var minHeight: CGFloat = 200
    /// Adaptive-height ceiling. Content taller than this scrolls inside the
    /// editor instead of stretching the field: a WKWebView consumes wheel
    /// events over its own area, so a full-content-height editor would turn
    /// most of the page into a dead scroll zone. Roughly 55–60% of a typical
    /// settings-window height.
    var maxHeight: CGFloat = 600

    @Environment(\.colorScheme) private var colorScheme
    /// Natural content height reported by the web editor; zero until the
    /// first report arrives, in which case the field keeps `minHeight`.
    @State private var contentHeight: CGFloat = 0

    /// Breathing room below the content — ~3 blank input lines, sized with
    /// the editor's own body metrics so it matches what a typed line
    /// actually occupies.
    private var inputAllowance: CGFloat {
        (MeetingNotesTypography.bodyFontSize * MeetingNotesTypography.webLineHeight).rounded() * 3
    }

    private var resolvedHeight: CGFloat {
        min(max(minHeight, contentHeight + inputAllowance), maxHeight)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarkdownWebEditorView(
                text: $text,
                documentId: documentId,
                readOnly: false,
                onContentHeightChange: { contentHeight = $0 }
            )

            if !placeholder.isEmpty,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: MeetingNotesTypography.bodyFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, MeetingNotesTypography.contentInset)
                    .padding(.top, MeetingNotesTypography.contentInset)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        // Fixed height driven by the reported content height, not minHeight:
        // a ScrollView proposes its own viewport height to children, and a
        // flexible frame would accept it, blowing an empty editor up to a
        // full screen. Fixed means "content + 3 lines", falling back to
        // `minHeight` only until the first height report arrives.
        .frame(height: resolvedHeight)
        .background(
            colorScheme == .dark
                ? Color(nsColor: .controlBackgroundColor).opacity(0.5)
                : Color.gray.opacity(0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color(nsColor: .separatorColor)
                        : Color.gray.opacity(0.18),
                    lineWidth: 1
                )
        }
    }
}
