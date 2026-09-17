import { StrictMode, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { AtomicCodeMirrorEditor } from '@atomic-editor/editor';
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
interface LoadPayload {
  documentId: string;
  markdown: string;
  readOnly: boolean;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        markdownChanged?: { postMessage: (body: { documentId: string; markdown: string }) => void };
        linkClicked?: { postMessage: (url: string) => void };
        editorReady?: { postMessage: (body: string) => void };
      };
    };
    __meetmemoBridge?: {
      load: (payload: LoadPayload) => void;
    };
  }
}

function App() {
  const [doc, setDoc] = useState<LoadPayload | null>(null);
  const [isSwitchingDocument, setIsSwitchingDocument] = useState(false);
  const docRef = useRef<LoadPayload | null>(null);
  const switchTimerRef = useRef<number | null>(null);
  const settleFrameRef = useRef<number | null>(null);
  // Distinguishes "this text change came from the editor itself" (already
  // reflected in the CM6 view; echoing it back via `load` would be a no-op
  // at best since markdownSource is mount-only, so we just skip posting it
  // back to Swift as a no-op change) from an incoming Swift-driven update.
  const lastEmittedRef = useRef<string | null>(null);

  useEffect(() => {
    // Theme (palette + type scale) is pushed in natively by
    // MarkdownEditorTheme.swift rather than derived from
    // prefers-color-scheme: this app drives its own light/dark setting, so
    // the system-level media query isn't the authority here.
    window.__meetmemoBridge = {
      load: (payload) => {
        lastEmittedRef.current = payload.markdown;
        const current = docRef.current;

        if (switchTimerRef.current !== null) {
          window.clearTimeout(switchTimerRef.current);
          switchTimerRef.current = null;
        }
        if (settleFrameRef.current !== null) {
          window.cancelAnimationFrame(settleFrameRef.current);
          settleFrameRef.current = null;
        }

        // The first document and in-place configuration updates should paint
        // immediately. A genuine document replacement keeps the old editor
        // visible for one very short fade, then lets the fully mounted new
        // editor fade in. This masks CodeMirror's required destroy/recreate
        // boundary without delaying normal typing or read-only changes.
        if (!current || current.documentId === payload.documentId) {
          docRef.current = payload;
          setDoc(payload);
          setIsSwitchingDocument(false);
          return;
        }

        setIsSwitchingDocument(true);
        switchTimerRef.current = window.setTimeout(() => {
          docRef.current = payload;
          setDoc(payload);
          switchTimerRef.current = null;

          settleFrameRef.current = window.requestAnimationFrame(() => {
            settleFrameRef.current = window.requestAnimationFrame(() => {
              setIsSwitchingDocument(false);
              settleFrameRef.current = null;
            });
          });
        }, 65);
      },
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
      if (switchTimerRef.current !== null) {
        window.clearTimeout(switchTimerRef.current);
      }
      if (settleFrameRef.current !== null) {
        window.cancelAnimationFrame(settleFrameRef.current);
      }
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
    <div className={`meetmemo-editor-transition${isSwitchingDocument ? ' is-switching' : ''}`}>
      <AtomicCodeMirrorEditor
        documentId={doc.documentId}
        markdownSource={doc.markdown}
        readOnly={doc.readOnly}
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
