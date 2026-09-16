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
/// `documentId` is the whole contract with the JS side: `markdownSource` is
/// read only once, at the underlying CodeMirror view's mount time — there is
/// no API to push new text into an already-mounted editor except by
/// changing `documentId`, which forces a full remount (fresh content, but
/// loses cursor/scroll/undo history). Callers must therefore only change
/// `documentId` on a genuine new-document boundary (switching meetings, a
/// freshly-completed AI generation) — never per keystroke, or every edit
/// would remount the editor out from under the user's cursor. The same
/// `documentId` with a different `readOnly` reconfigures the live view in
/// place instead (no remount) — that's how the edit/preview toggle works
/// without losing scroll position, which is strictly better than the old
/// implementation's two-separate-views swap.
struct MarkdownWebEditorView: NSViewRepresentable {
    @Binding var text: String
    let documentId: String
    var readOnly: Bool

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "markdownChanged")
        configuration.userContentController.add(context.coordinator, name: "linkClicked")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        context.coordinator.webView = webView

        // No `subdirectory:` — Xcode's synchronized resource group copies
        // loose files into Contents/Resources/ as a flat directory (any
        // MarkdownEditorWeb/ nesting from the source tree is flattened
        // away at build time), and the web bundle itself is built flat to
        // match (see web/markdown-editor/vite.config.ts).
        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            assertionFailure("index.html (the notes web editor bundle) not found in the app bundle — did it get built? See web/markdown-editor/README.md.")
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.sync(documentId: documentId, markdown: text, readOnly: readOnly)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "markdownChanged")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "linkClicked")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var text: Binding<String>
        weak var webView: WKWebView?

        private var isPageReady = false
        private var pendingLoad: LoadState?
        private var lastLoaded: LoadState?

        private struct LoadState: Equatable {
            let documentId: String
            let markdown: String
            let readOnly: Bool
        }

        init(text: Binding<String>) {
            self.text = text
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageReady = true
            if let pending = pendingLoad {
                push(pending)
                pendingLoad = nil
            }
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
            let state = LoadState(documentId: documentId, markdown: markdown, readOnly: readOnly)
            guard state.documentId != lastLoaded?.documentId || state.readOnly != lastLoaded?.readOnly else { return }

            guard isPageReady else {
                pendingLoad = state
                return
            }
            push(state)
        }

        private func push(_ state: LoadState) {
            lastLoaded = state
            struct Payload: Encodable {
                let documentId: String
                let markdown: String
                let readOnly: Bool
            }
            guard let data = try? JSONEncoder().encode(Payload(documentId: state.documentId, markdown: state.markdown, readOnly: state.readOnly)),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.__meetmemoBridge && window.__meetmemoBridge.load(\(json));")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "markdownChanged":
                guard let newText = message.body as? String, newText != text.wrappedValue else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.text.wrappedValue = newText
                }
            case "linkClicked":
                guard let urlString = message.body as? String, let url = URL(string: urlString) else { return }
                NSWorkspace.shared.open(url)
            default:
                break
            }
        }
    }
}
