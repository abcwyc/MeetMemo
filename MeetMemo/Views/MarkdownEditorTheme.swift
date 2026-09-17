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
    /// properties are inherited by the editor through the explicit
    /// `:root .atomic-cm-editor` bridge in `overrides.css`. That bridge is
    /// needed because declarations on the editor element itself would
    /// otherwise override values inherited from the document root.
    static func cssVariables(theme: MarkdownTheme, isDark: Bool) -> [String: String] {
        var variables: [String: String] = [
            "--atomic-editor-body-size": "\(Int(MeetingNotesTypography.bodyFontSize))px",
            "--atomic-editor-measure": "100%",
            "--atomic-editor-font-mono": monoFontFamily(for: theme)
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

            let accent = accentColor(for: theme, isDark: isDark)
            variables["--atomic-editor-accent"] = css(accent)
            variables["--atomic-editor-accent-bright"] = css(accent)
            variables["--atomic-editor-accent-soft"] = css(accent.withAlphaComponent(0.3))
            variables["--atomic-editor-link"] = css(accent)
            variables["--atomic-editor-link-hover"] = css(accent)
            variables["--atomic-editor-selection-bg"] = css(.selectedTextBackgroundColor)

            variables["--notes-border-default"] = isDark ? "#30363d" : "#d0d7de"
            variables["--notes-border-muted"] = isDark ? "#2f3033" : "#e5e7eb"
            variables["--notes-canvas-subtle"] = isDark ? "#242426" : "#f6f8fa"
            variables["--notes-neutral-muted"] = isDark ? "rgba(110,118,129,0.4)" : "rgba(175,184,193,0.2)"
            variables["--notes-fg-muted"] = isDark ? "#a1a1aa" : "#59636e"
            variables["--notes-row-alt"] = isDark ? "#242426" : "#f6f8fa"
            variables["--notes-quote-bg"] = isDark ? "rgba(255,255,255,0.045)" : "rgba(0,0,0,0.035)"

            variables["--atomic-editor-body-leading"] = lineHeight(for: theme)
            variables["--atomic-editor-font"] = fontFamily(for: theme)

            // Matches the inline-code / table-header fill the native
            // renderer uses.
            variables["--atomic-editor-code-bg"] = css(NSColor.secondaryLabelColor.withAlphaComponent(0.12))
        }

        return variables
    }

    private static func fontFamily(for theme: MarkdownTheme) -> String {
        switch theme {
        case .meetMemo:
            return "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
        case .github:
            return "\"Mona Sans\", -apple-system, BlinkMacSystemFont, \"Segoe UI\", \"Noto Sans\", Helvetica, Arial, sans-serif"
        case .bear:
            return "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
        case .typora:
            return "Vollkorn, Palatino, \"Songti SC\", \"Noto Serif CJK SC\", Times, serif"
        case .sspai:
            return "Helvetica, Arial, \"PingFang SC\", \"Microsoft YaHei\", \"WenQuanYi Micro Hei\", sans-serif"
        }
    }

    private static func monoFontFamily(for theme: MarkdownTheme) -> String {
        switch theme {
        case .bear:
            return "\"Roboto Mono\", ui-monospace, SFMono-Regular, Menlo, monospace"
        case .sspai:
            return "Courier, Menlo, Monaco, Consolas, monospace"
        case .meetMemo, .github, .typora:
            return "ui-monospace, SFMono-Regular, \"SF Mono\", Menlo, Consolas, monospace"
        }
    }

    private static func lineHeight(for theme: MarkdownTheme) -> String {
        switch theme {
        case .meetMemo: return "1.55"
        case .github: return "1.5"
        case .bear: return "1.5"
        case .typora: return "1.53"
        case .sspai: return "1.8"
        }
    }

    private static func accentColor(for theme: MarkdownTheme, isDark: Bool) -> NSColor {
        switch theme {
        case .meetMemo:
            return isDark
                ? NSColor(srgbRed: 0.40, green: 0.72, blue: 1.0, alpha: 1)
                : NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
        case .github:
            return isDark
                ? NSColor(srgbRed: 0.345, green: 0.651, blue: 1.0, alpha: 1)
                : NSColor(srgbRed: 0.035, green: 0.412, blue: 0.855, alpha: 1)
        case .bear:
            return isDark
                ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1)
                : NSColor(srgbRed: 0.85, green: 0.27, blue: 0.29, alpha: 1)
        case .typora:
            return isDark
                ? NSColor(srgbRed: 0.46, green: 0.70, blue: 0.91, alpha: 1)
                : NSColor(srgbRed: 0.25, green: 0.51, blue: 0.77, alpha: 1)
        case .sspai:
            return isDark
                ? NSColor(srgbRed: 1.0, green: 0.49, blue: 0.47, alpha: 1)
                : NSColor(srgbRed: 0.95, green: 0.18, blue: 0.15, alpha: 1)
        }
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
