import AppKit
import SwiftUI
import WebKit

/// The meeting notes editor: a `WKWebView` hosting Atomic Editor
/// (CodeMirror 6, Obsidian-style live preview + WYSIWYG tables), replacing
/// the earlier hand-built TextKit 1 implementation — see
/// `web/markdown-editor/README.md` for why. Editing and rendering are the
/// same surface (`readOnly` just toggles typing, it isn't a different view),
/// which is what "merge edit and preview" means here.
///
/// `documentId` is the core of the contract with the JS side:
/// `markdownSource` is read only once, at the underlying CodeMirror view's
/// mount time — there is no API to push new text into an already-mounted
/// editor except by changing `documentId`, which forces a full remount
/// (fresh content, but loses cursor/scroll/undo history). Callers must
/// therefore only change `documentId` on a genuine new-document boundary
/// (switching meetings, a freshly-completed AI generation) — never per
/// keystroke, or every edit would remount the editor out from under the
/// user's cursor. The same `documentId` with a different `readOnly`
/// reconfigures the live view in place instead (no remount) — that's how
/// the edit/preview toggle works without losing scroll position, which is
/// strictly better than the old implementation's two-separate-views swap.
///
/// The coordinator additionally reloads when `text` changes *without* the
/// caller changing `documentId` and without the change having come from the
/// editor itself — see `contentChangedExternally` in `sync`. That covers
/// content arriving asynchronously for a document the editor has already
/// mounted. The meeting list now preloads before presentation, but this
/// remains necessary for external replacements such as regenerated notes.
struct MarkdownWebEditorView: NSViewRepresentable {
    @Binding var text: String
    let documentId: String
    var readOnly: Bool

    /// Drives the editor's palette. Read from the SwiftUI environment rather
    /// than the web view's `effectiveAppearance` so it tracks the app's own
    /// light/dark setting (`AppearanceManager` forces it app-wide) at the
    /// same moment the rest of the UI does.
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var markdownThemeManager = MarkdownThemeManager.shared

    /// Custom scheme the bundled web editor loads under, instead of
    /// `file://` — WKWebView's `file://` origin is unreliable for
    /// `<script type="module">` (our entry point), and a custom
    /// `WKURLSchemeHandler` origin is treated as a real web origin instead,
    /// which is the standard fix for embedding a built web app bundle in a
    /// WKWebView.
    static let scheme = "meetmemo-editor"

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(BundleResourceSchemeHandler(), forURLScheme: Self.scheme)
        configuration.userContentController.add(context.coordinator, name: "markdownChanged")
        configuration.userContentController.add(context.coordinator, name: "linkClicked")
        configuration.userContentController.add(context.coordinator, name: "editorReady")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        context.coordinator.webView = webView

        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://local/index.html")!))

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.syncTheme(
            theme: markdownThemeManager.theme,
            isDark: colorScheme == .dark
        )
        context.coordinator.sync(documentId: documentId, markdown: text, readOnly: readOnly)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "markdownChanged")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "linkClicked")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editorReady")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var text: Binding<String>
        weak var webView: WKWebView?

        /// True once the JS side's `editorReady` message has arrived —
        /// meaning `window.__meetmemoBridge` genuinely exists and it's safe
        /// to call `.load(...)` on it. Deliberately *not* set from
        /// `didFinish navigation`: that fires as soon as the page/module
        /// script finishes loading, which can race ahead of React's
        /// `useEffect` (where the bridge object gets attached) by a few
        /// milliseconds. A push that lands in that window calls a
        /// nonexistent `window.__meetmemoBridge.load` — silently, since the
        /// call site defensively no-ops rather than throwing — and because
        /// `push()` unconditionally records the state as delivered, it was
        /// never retried: the editor stayed permanently blank for that
        /// document. Waiting for the JS side's own readiness signal instead
        /// of inferring it from a page-load event closes that race
        /// entirely, rather than papering over it with a retry/delay.
        private var isBridgeReady = false
        private var pendingLoad: MarkdownEditorDocumentState?
        private var lastLoaded: MarkdownEditorDocumentState?
        private struct ThemeState: Equatable {
            let theme: MarkdownTheme
            let isDark: Bool
        }

        private var appliedTheme: ThemeState?
        private var pendingTheme: ThemeState?

        /// The text the editor itself last reported. Lets `sync` tell "the
        /// app handed us different content" apart from "our own edit came
        /// back around through the binding" — the latter must never force a
        /// reload, or every keystroke would remount the editor and drop the
        /// caret.
        private var lastEmittedByEditor: MarkdownEditorEmission?
        /// Exact remount-qualified id currently hosted by the JS editor.
        /// Messages from an editor instance that was just replaced are
        /// ignored instead of being written into the newly selected meeting.
        private var activeBridgeDocumentId: String?

        /// Makes "same document, different content" look like a new document
        /// to the JS side. AtomicCodeMirrorEditor reads `markdownSource`
        /// once, at mount, so a changed `documentId` is the only way to get
        /// new content on screen.
        private var reloadNonce = 0

        init(text: Binding<String>) {
            self.text = text
        }

        /// Called on every SwiftUI update pass (including ones triggered by
        /// this editor's own typing echoing back through the binding). Only
        /// actually talks to JS when something meaningful changed —
        /// `documentId` (new document: push fresh content) or `readOnly`
        /// (toggle, same document: push without remounting). A same-
        /// document, same-readOnly call (the common case: every keystroke)
        /// is a no-op here, since re-pushing `markdownSource` for an
        /// unchanged `documentId` would be ignored by the library anyway
        /// (mount-time-only) and would just waste a JS round-trip.
        func sync(documentId: String, markdown: String, readOnly: Bool) {
            let state = MarkdownEditorDocumentState(documentId: documentId, markdown: markdown, readOnly: readOnly)
            let action = MarkdownEditorSyncPolicy.action(
                for: state,
                lastPushed: lastLoaded,
                lastEmittedByEditor: lastEmittedByEditor
            )

            guard case .push(let remount) = action else { return }

            guard isBridgeReady else {
                pendingLoad = state
                return
            }
            push(state, remount: remount)
        }

        /// Re-pushes the palette only when it actually changed. Called on
        /// every SwiftUI update pass, so it has to be cheap in the common
        /// (unchanged) case.
        func syncTheme(theme: MarkdownTheme, isDark: Bool) {
            let state = ThemeState(theme: theme, isDark: isDark)
            guard state != appliedTheme else { return }
            guard isBridgeReady else {
                pendingTheme = state
                return
            }
            applyTheme(state)
        }

        private func applyTheme(_ state: ThemeState) {
            appliedTheme = state
            let variables = MarkdownEditorTheme.cssVariables(theme: state.theme, isDark: state.isDark)
            guard let data = try? JSONSerialization.data(withJSONObject: variables),
                  let json = String(data: data, encoding: .utf8) else { return }
            // `data-theme` still matters for the handful of variables we
            // don't override (code-syntax colors, find highlights): it picks
            // which of the package's own palettes those fall back to.
            let script = """
            (function (colorTheme, markdownTheme, vars) {
              document.documentElement.setAttribute('data-theme', colorTheme);
              document.documentElement.setAttribute('data-markdown-theme', markdownTheme);
              var style = document.documentElement.style;
              Object.keys(vars).forEach(function (key) { style.setProperty(key, vars[key]); });
            })('\(state.isDark ? "dark" : "light")', '\(state.theme.rawValue)', \(json));
            """
            webView?.evaluateJavaScript(script)
        }

        private func push(_ state: MarkdownEditorDocumentState, remount: Bool = true) {
            lastLoaded = state
            if remount {
                // Varying the id is the only lever that makes the JS side
                // rebuild the view on new content; leaving it alone lets a
                // readOnly flip reconfigure in place, keeping caret and
                // scroll position.
                reloadNonce += 1
            }
            struct Payload: Encodable {
                let documentId: String
                let markdown: String
                let readOnly: Bool
            }
            let bridgeDocumentId = "\(state.documentId)#\(reloadNonce)"
            let payload = Payload(
                documentId: bridgeDocumentId,
                markdown: state.markdown,
                readOnly: state.readOnly
            )
            guard let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            activeBridgeDocumentId = bridgeDocumentId
            webView?.evaluateJavaScript("window.__meetmemoBridge && window.__meetmemoBridge.load(\(json));")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "markdownChanged":
                guard let payload = message.body as? [String: Any],
                      let bridgeDocumentId = payload["documentId"] as? String,
                      let newText = payload["markdown"] as? String,
                      bridgeDocumentId == activeBridgeDocumentId,
                      let activeDocument = lastLoaded else { return }
                lastEmittedByEditor = MarkdownEditorEmission(
                    documentId: activeDocument.documentId,
                    markdown: newText
                )
                guard newText != text.wrappedValue else { return }
                // WKScriptMessageHandler is invoked on the main thread. Apply
                // the binding synchronously so a following meeting switch or
                // view dismissal cannot overtake the final edit. The caller's
                // binding is also scoped to its meeting id as a second guard
                // against an already-queued callback from an old document.
                text.wrappedValue = newText
            case "linkClicked":
                guard let urlString = message.body as? String, let url = URL(string: urlString) else { return }
                NSWorkspace.shared.open(url)
            case "editorReady":
                isBridgeReady = true
                // Theme first, so the editor's first paint is already in the
                // right palette instead of flashing the package's defaults.
                if let pendingTheme {
                    applyTheme(pendingTheme)
                    self.pendingTheme = nil
                }
                if let pending = pendingLoad {
                    push(pending)
                    pendingLoad = nil
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[MarkdownWebEditorView] navigation failed: %@", error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[MarkdownWebEditorView] provisional navigation failed: %@", error.localizedDescription)
        }
    }
}

/// Serves the bundled web editor's files (flat in Contents/Resources/, see
/// vite.config.ts) over a custom scheme instead of `file://`. Requests are
/// matched by filename only (via `Bundle.main.url(forResource:withExtension:)`),
/// independent of the request path, since Xcode's synchronized resource
/// group already flattens any source-tree nesting away at build time.
private final class BundleResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let filename = (url.path as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        guard let fileURL = Bundle.main.url(forResource: base, withExtension: ext),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType: String
        switch ext {
        case "html": mimeType = "text/html"
        case "js": mimeType = "application/javascript"
        case "css": mimeType = "text/css"
        case "json": mimeType = "application/json"
        default: mimeType = "application/octet-stream"
        }

        let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
