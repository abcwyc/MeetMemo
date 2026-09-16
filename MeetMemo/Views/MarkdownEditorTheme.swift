import AppKit

/// Bridges the app's design tokens into the embedded web editor as CSS
/// custom properties.
///
/// This exists because a WKWebView can't see any of it on its own: it has no
/// access to the user's macOS accent color or to AppKit's semantic colors,
/// and this app additionally drives its own light/dark setting
/// (`AppearanceManager` forces `NSApplication.shared.appearance`), so the
/// page can't infer the right theme from `prefers-color-scheme` either.
/// Resolving the values natively and pushing them in keeps one source of
/// truth — the editor follows the system accent and the app's own appearance
/// toggle instead of shipping a second, drifting palette.
enum MarkdownEditorTheme {
    /// CSS custom properties to set on `document.documentElement`. Inline
    /// custom properties outrank any selector-based default in the package's
    /// stylesheet, so these win without `!important`.
    static func cssVariables(isDark: Bool) -> [String: String] {
        var variables: [String: String] = [
            "--atomic-editor-body-size": "\(Int(MeetingNotesTypography.bodyFontSize))px",
            "--atomic-editor-body-leading": "\(MeetingNotesTypography.webLineHeight)",
            // Fill the pane. The package caps the text column at 70ch and
            // centers it (`margin-inline: auto`), which in this app's notes
            // pane left wide empty gutters on both sides and didn't respond
            // to window width at all.
            "--atomic-editor-measure": "100%",
            "--atomic-editor-font": "-apple-system, system-ui, BlinkMacSystemFont, sans-serif",
            "--atomic-editor-font-mono": "ui-monospace, SFMono-Regular, Menlo, monospace"
        ]

        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            variables["--atomic-editor-fg"] = css(.labelColor)
            variables["--atomic-editor-fg-muted"] = css(.secondaryLabelColor)
            variables["--atomic-editor-fg-faint"] = css(.tertiaryLabelColor)

            // NOT transparent: the package uses `--atomic-editor-bg` for the
            // find field and `-bg-panel`/`-bg-surface` for popovers, tooltips
            // and hover states, which need a real backdrop. The editor's own
            // root stays transparent independently of these (its theme hard-
            // codes `background: transparent`), so the SwiftUI card behind it
            // still shows through.
            variables["--atomic-editor-bg"] = css(.textBackgroundColor)
            variables["--atomic-editor-bg-panel"] = css(.controlBackgroundColor)
            variables["--atomic-editor-bg-surface"] = css(.windowBackgroundColor)
            variables["--atomic-editor-border"] = css(.separatorColor)

            let accent = NSColor.controlAccentColor
            variables["--atomic-editor-accent"] = css(accent)
            variables["--atomic-editor-accent-bright"] = css(accent)
            variables["--atomic-editor-accent-soft"] = css(accent.withAlphaComponent(0.3))
            variables["--atomic-editor-link"] = css(accent)
            variables["--atomic-editor-link-hover"] = css(accent)
            variables["--atomic-editor-selection-bg"] = css(.selectedTextBackgroundColor)

            // Matches the inline-code / table-header fill the native
            // renderer uses.
            variables["--atomic-editor-code-bg"] = css(NSColor.secondaryLabelColor.withAlphaComponent(0.12))
        }

        return variables
    }

    /// Serializes an NSColor into a CSS `rgba(...)`. Semantic colors are
    /// dynamic (they resolve differently per appearance), which is why
    /// callers resolve them inside `performAsCurrentDrawingAppearance`
    /// before this runs.
    private static func css(_ color: NSColor) -> String {
        guard let resolved = color.usingColorSpace(.sRGB) else { return "initial" }
        let red = Int((resolved.redComponent * 255).rounded())
        let green = Int((resolved.greenComponent * 255).rounded())
        let blue = Int((resolved.blueComponent * 255).rounded())
        let alpha = String(format: "%.3f", resolved.alphaComponent)
        return "rgba(\(red), \(green), \(blue), \(alpha))"
    }
}
