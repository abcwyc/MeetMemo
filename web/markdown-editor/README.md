# Meeting notes web editor

The live-preview markdown editor for the AI Notes tab: a thin React wrapper
around [Atomic Editor](https://github.com/kenforthewin/atomic-editor)
(CodeMirror 6, Obsidian-style inline live preview, WYSIWYG tables,
click-to-toggle checkboxes), embedded into the native app via `WKWebView`
(see `MarkdownWebEditorView.swift`).

This replaced an earlier hand-built TextKit 1 implementation
(`MarkdownLiveStyler`/`MarkdownLiveEditorView`/`MarkdownLiveLayoutManager`,
still visible in git history) that reparsed and restyled the *entire*
document on every keystroke — fine for short notes, but O(document length)
per character typed, which became noticeably laggy on longer notes. Atomic
Editor's CM6 foundation does incremental, viewport-virtualized updates
instead (its own docs: "editing a paragraph in a 50KB doc costs O(change
size), not O(doc)").

## Why this isn't part of the normal Xcode build

MeetMemo's build is pure `xcodebuild` — no Node.js in the pipeline. So this
package's **build output is committed**, at
`../../MeetMemo/Resources/MarkdownEditorWeb/` (outside this directory,
picked up automatically as an Xcode bundle resource since MeetMemo's project
uses file-system-synchronized groups — no `.xcodeproj` edits needed when the
built files change).

**Rebuild and commit the output whenever you change `src/`:**

```bash
cd web/markdown-editor
npm install   # first time, or after a dependency bump
npm run build # type-checks, then builds into MeetMemo/Resources/MarkdownEditorWeb/
```

Then `git add` the changed files under `MeetMemo/Resources/MarkdownEditorWeb/`
alongside your `src/` change, in the same commit.

**Don't reintroduce a subdirectory in the build output.** Xcode's
synchronized resource group copies loose files into `Contents/Resources/`
as a flat directory — any nesting here gets silently flattened away at
build time. `vite.config.ts` sets `assetsDir: '.'` specifically so
`index.html`'s script/link tags reference bare sibling filenames
(`./index-XXXX.js`) that survive that flattening; a normal Vite build
(`assets/index-XXXX.js`) would break at runtime with no build-time error.

## Native bridge

See the contract documented at the top of `src/main.tsx` and in
`MeetMemo/Views/MarkdownWebEditorView.swift`. Summary:

- **Swift → JS**: `window.__meetmemoBridge.load({ documentId, markdown, readOnly })`.
  Swift only bumps `documentId` on a genuine new-document boundary (switching
  meetings, a fresh AI generation landing) — never per keystroke. The same
  `documentId` with a different `readOnly` reconfigures the live view in
  place (no remount, scroll/cursor preserved) — this is how the edit/preview
  toggle works without losing your place.
- **JS → Swift**: `window.webkit.messageHandlers.markdownChanged.postMessage(text)`
  on every edit, and `.linkClicked.postMessage(url)` when a rendered link is
  clicked (opened via `NSWorkspace`, since a bare `WKWebView` has no window
  chrome for `window.open` to target).

`markdownSource` is read only at `AtomicCodeMirrorEditor` mount time — there
is no "push new text into an already-mounted editor" API in the library
itself, only the `documentId`-triggered remount above. That's why active AI
note *streaming* still renders through the plain SwiftUI `RenderedNotesView`
(cheap re-render per published chunk) rather than this editor — mounting a
CM6 instance per streamed token would be constant, janky remounts. The web
editor mounts once streaming settles.

## Known limitation carried over from the design discussion

A cell containing a literal `|` isn't a concern here — Atomic Editor's own
table parser handles pipe-table syntax properly (unlike the retired hand-
built version's parser). No known round-trip gaps identified yet; file one
if you find one.
