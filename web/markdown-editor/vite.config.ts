import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Builds a static bundle consumed by MarkdownWebEditorView (WKWebView) via
// loadFileURL. Output goes directly into the Xcode project's Resources
// folder — MeetMemo's PBXFileSystemSynchronizedRootGroup picks up new files
// under MeetMemo/ automatically, no .xcodeproj edits needed. Rebuild with
// `npm run build` whenever src/ changes; the dist/ output is committed
// (this project has no Node build step in its normal `xcodebuild` pipeline).
//
// assetsDir is '.' (flat, no assets/ subfolder) deliberately: Xcode's
// synchronized resource group copies loose files into Contents/Resources/
// as a FLAT directory — any subdirectory structure here (the default
// assets/ subfolder) gets silently flattened away at build time, which
// would break index.html's "./assets/foo.js" references. Keeping
// everything as siblings in one flat directory survives that flattening
// unchanged.
export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: '../../MeetMemo/Resources/MarkdownEditorWeb',
    emptyOutDir: true,
    assetsDir: '.',
  },
});
