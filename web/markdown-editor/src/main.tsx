import { StrictMode, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { AtomicCodeMirrorEditor } from '@atomic-editor/editor';
import '@atomic-editor/editor/styles.css';

// Bridge contract with MarkdownWebEditorView.swift (WKScriptMessageHandler +
// evaluateJavaScript):
//
// JS -> Swift: window.webkit.messageHandlers.markdownChanged.postMessage(text)
//   Fired on every edit (raw markdown string; WKScriptMessage round-trips a
//   bare JS string as an NSString, no JSON wrapper needed).
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
        markdownChanged?: { postMessage: (body: string) => void };
        linkClicked?: { postMessage: (url: string) => void };
      };
    };
    __meetmemoBridge?: {
      load: (payload: LoadPayload) => void;
    };
  }
}

function applySystemTheme() {
  const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  document.documentElement.setAttribute('data-theme', isDark ? 'dark' : 'light');
}

function App() {
  const [doc, setDoc] = useState<LoadPayload | null>(null);
  // Distinguishes "this text change came from the editor itself" (already
  // reflected in the CM6 view; echoing it back via `load` would be a no-op
  // at best since markdownSource is mount-only, so we just skip posting it
  // back to Swift as a no-op change) from an incoming Swift-driven update.
  const lastEmittedRef = useRef<string | null>(null);

  useEffect(() => {
    applySystemTheme();
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = () => applySystemTheme();
    media.addEventListener('change', onChange);

    window.__meetmemoBridge = {
      load: (payload) => {
        lastEmittedRef.current = payload.markdown;
        setDoc(payload);
      },
    };

    return () => {
      media.removeEventListener('change', onChange);
      delete window.__meetmemoBridge;
    };
  }, []);

  const handleChange = (text: string) => {
    if (text === lastEmittedRef.current) return;
    lastEmittedRef.current = text;
    window.webkit?.messageHandlers?.markdownChanged?.postMessage(text);
  };

  // Nothing to render until Swift's first load() call arrives (typically
  // milliseconds after didFinish navigation).
  if (!doc) return null;

  return (
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
  );
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
