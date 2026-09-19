import { StrictMode, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { AtomicCodeMirrorEditor } from '@atomic-editor/editor';
import { Facet } from '@codemirror/state';
import { EditorView, ViewPlugin } from '@codemirror/view';
import '@atomic-editor/editor/styles.css';
// Must come after the package's stylesheet — see the header comment in
// overrides.css for why the order is load-bearing.
import './overrides.css';

// Bridge contract with MarkdownWebEditorView.swift (WKScriptMessageHandler +
// evaluateJavaScript):
//
// JS -> Swift: markdownChanged.postMessage({ documentId, markdown })
//   Fired on every edit. The mounted document id lets Swift reject a late
//   callback from an editor instance that was replaced during meeting switch.
// JS -> Swift: window.webkit.messageHandlers.linkClicked.postMessage(url)
//   A rendered link was clicked; Swift opens it via NSWorkspace.
//
// Swift -> JS: window.__meetmemoBridge.load({ documentId, markdown, readOnly })
//   Called once after the page's first navigation finishes (initial content),
//   and again whenever Swift wants to reflect a genuinely new document
//   state: switching meetings, a fresh AI generation landing, or the
//   edit/preview toggle. `documentId` is the whole story here — per
//   AtomicCodeMirrorEditor's own contract, `markdownSource` is read only at
//   mount time, and changing `documentId` is what triggers a real remount
//   with the new content; the *same* documentId with a different `readOnly`
//   just reconfigures the live view in place (no remount, scroll/cursor
//   preserved). Swift is responsible for only bumping documentId on real
//   document-identity changes — never per keystroke, or every edit would
//   remount and lose cursor/undo history.
// Swift -> JS: window.__meetmemoBridge.updateMarkdown({ documentId, markdown })
//   Replaces the content of the already-mounted, read-only CodeMirror view.
//   AI generation uses this path so streamed chunks keep the exact same
//   renderer and selected theme as the editable document without remounting
//   CodeMirror for every chunk.
interface LoadPayload {
  documentId: string;
  markdown: string;
  readOnly: boolean;
}

interface MarkdownUpdatePayload {
  documentId: string;
  markdown: string;
}

interface ActiveEditor {
  documentId: string;
  view: EditorView;
}

const bridgeDocumentId = Facet.define<string, string>({
  combine: (values) => values[0] ?? '',
});

let activeEditor: ActiveEditor | null = null;
let editorReadyListener: ((editor: ActiveEditor) => void) | null = null;

/// Last content height reported to Swift. Deduplicates so the update
/// listener can run on every editor update without spamming the bridge.
let lastReportedHeight = -1;

/// Natural document height, independent of the web view's frame.
///
/// Built from `view.contentHeight` (CM6's measured height of the document's
/// lines) plus the *top* paddings/borders of the editor chrome. The content
/// element's bottom padding is deliberately excluded: it is `20vh` of the
/// web view (a scroll-past-end buffer for the notes editor), so including
/// it would feed the reported height back into the frame and loop. Callers
/// that want breathing room below the text add their own fixed allowance.
const measureNaturalHeight = (view: EditorView): number | null => {
  const content = view.contentDOM;
  const scroller = view.scrollDOM;
  const editor =
    (scroller.closest('.atomic-cm-editor') as HTMLElement | null) ??
    scroller.parentElement;
  if (!content || !scroller || !editor) return null;

  const topSpacing = (el: Element) => {
    const cs = getComputedStyle(el);
    return (
      (parseFloat(cs.paddingTop) || 0) +
      (parseFloat(cs.borderTopWidth) || 0)
    );
  };

  return Math.ceil(
    view.contentHeight + topSpacing(content) + topSpacing(scroller) + topSpacing(editor)
  );
};

const reportEditorHeight = (view: EditorView, force = false) => {
  const height = measureNaturalHeight(view);
  if (height == null || height <= 0) return false;
  if (!force && Math.abs(height - lastReportedHeight) < 0.5) return false;
  lastReportedHeight = height;
  window.webkit?.messageHandlers?.editorHeightChanged?.postMessage(height);
  return true;
};

/// Content height right after a fresh CodeMirror mount can still read 0 for
/// a frame or two (CM6 measures lazily). Poll a few animation frames until
/// the first real measurement lands.
const reportWhenMeasured = (view: EditorView) => {
  let attempts = 0;
  const tick = () => {
    if (reportEditorHeight(view)) return;
    if (++attempts < 30) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
};

const bridgeViewPlugin = ViewPlugin.define((view) => {
  const editor = {
    documentId: view.state.facet(bridgeDocumentId),
    view,
  };
  activeEditor = editor;
  reportWhenMeasured(view);
  editorReadyListener?.(editor);
  return {
    update: (update) => {
      reportEditorHeight(update.view);
    },
    destroy: () => {
      if (activeEditor?.view === view) activeEditor = null;
    },
  };
});

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        markdownChanged?: { postMessage: (body: { documentId: string; markdown: string }) => void };
        linkClicked?: { postMessage: (url: string) => void };
        editorReady?: { postMessage: (body: string) => void };
        editorHeightChanged?: { postMessage: (height: number) => void };
      };
    };
    __meetmemoBridge?: {
      load: (payload: LoadPayload) => void;
      updateMarkdown: (payload: MarkdownUpdatePayload) => void;
    };
    /// Invoked by Swift after a theme push: CSS-variable-driven font and
    /// padding changes reshape the document without any CodeMirror state
    /// update, so the editor can't see them on its own.
    __meetmemoEditorResized?: () => void;
  }
}

function App() {
  const [doc, setDoc] = useState<LoadPayload | null>(null);
  // Distinguishes "this text change came from the editor itself" (already
  // reflected in the CM6 view; echoing it back via `load` would be a no-op
  // at best since markdownSource is mount-only, so we just skip posting it
  // back to Swift as a no-op change) from an incoming Swift-driven update.
  const lastEmittedRef = useRef<string | null>(null);
  const activeDocumentIdRef = useRef<string | null>(null);
  const pendingMarkdownUpdateRef = useRef<MarkdownUpdatePayload | null>(null);

  const applyMarkdownUpdate = (editor: ActiveEditor, payload: MarkdownUpdatePayload) => {
    if (payload.documentId !== editor.documentId) return;

    const { view } = editor;
    const currentMarkdown = view.state.doc.toString();
    if (currentMarkdown === payload.markdown) return;

    const scroller = view.scrollDOM;
    const wasFollowingTail =
      scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48;

    // Prevent the programmatic replacement from being echoed back to
    // Swift as though it were a user edit.
    lastEmittedRef.current = payload.markdown;
    let sharedPrefixLength = 0;
    const prefixLimit = Math.min(currentMarkdown.length, payload.markdown.length);
    while (
      sharedPrefixLength < prefixLimit &&
      currentMarkdown.charCodeAt(sharedPrefixLength) ===
        payload.markdown.charCodeAt(sharedPrefixLength)
    ) {
      sharedPrefixLength += 1;
    }

    view.dispatch({
      changes: {
        from: sharedPrefixLength,
        to: view.state.doc.length,
        insert: payload.markdown.slice(sharedPrefixLength),
      },
    });

    if (wasFollowingTail) {
      requestAnimationFrame(() => {
        scroller.scrollTop = scroller.scrollHeight;
      });
    }
  };

  useEffect(() => {
    // Theme (palette + type scale) is pushed in natively by
    // MarkdownEditorTheme.swift rather than derived from
    // prefers-color-scheme: this app drives its own light/dark setting, so
    // the system-level media query isn't the authority here.
    window.__meetmemoBridge = {
      load: (payload) => {
        activeDocumentIdRef.current = payload.documentId;
        pendingMarkdownUpdateRef.current = null;
        lastEmittedRef.current = payload.markdown;
        // React keeps the old tree painted until this update commits, so an
        // additional fade/delay only makes a local document switch look like
        // a page refresh. Let Atomic Editor replace the CodeMirror instance
        // in the same commit instead.
        setDoc(payload);
      },
      updateMarkdown: (payload) => {
        if (payload.documentId !== activeDocumentIdRef.current) return;
        if (!activeEditor || activeEditor.documentId !== payload.documentId) {
          // `load` updates React asynchronously. Keep only the latest chunk
          // until the CodeMirror view for that document has actually mounted.
          pendingMarkdownUpdateRef.current = payload;
          return;
        }
        applyMarkdownUpdate(activeEditor, payload);
      },
    };
    window.__meetmemoEditorResized = () => {
      const view = activeEditor?.view;
      if (!view) return;
      requestAnimationFrame(() => reportEditorHeight(view, true));
    };
    editorReadyListener = (editor) => {
      const pending = pendingMarkdownUpdateRef.current;
      if (
        !pending ||
        pending.documentId !== editor.documentId ||
        pending.documentId !== activeDocumentIdRef.current
      ) return;
      pendingMarkdownUpdateRef.current = null;
      applyMarkdownUpdate(editor, pending);
    };
    // Tell Swift the bridge object actually exists now, so it knows it's
    // safe to call window.__meetmemoBridge.load(...) — see
    // MarkdownWebEditorView.swift's isBridgeReady for why this can't just
    // be "the page finished loading" (didFinish navigation): that fires
    // before this effect is guaranteed to have run, and a push that races
    // ahead of it silently no-ops (the bridge object isn't there yet) with
    // no retry, permanently blanking the editor.
    window.webkit?.messageHandlers?.editorReady?.postMessage('');

    return () => {
      editorReadyListener = null;
      delete window.__meetmemoBridge;
    };
  }, []);

  const handleChange = (text: string) => {
    if (text === lastEmittedRef.current) return;
    lastEmittedRef.current = text;
    if (!doc) return;
    window.webkit?.messageHandlers?.markdownChanged?.postMessage({
      documentId: doc.documentId,
      markdown: text,
    });
  };

  // Nothing to render until Swift's first load() call arrives — which it
  // sends once it receives our editorReady message above.
  if (!doc) return null;

  return (
    <div className="meetmemo-editor-host">
      <AtomicCodeMirrorEditor
        documentId={doc.documentId}
        markdownSource={doc.markdown}
        readOnly={doc.readOnly}
        extensions={[bridgeDocumentId.of(doc.documentId), bridgeViewPlugin]}
        onMarkdownChange={handleChange}
        onLinkClick={(url) => {
          // Hand off to Swift (NSWorkspace.shared.open) — a bare WKWebView has
          // no window chrome for window.open to target, and this keeps
          // "open in the system browser" a visible native action.
          window.webkit?.messageHandlers?.linkClicked?.postMessage(url);
        }}
      />
    </div>
  );
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
