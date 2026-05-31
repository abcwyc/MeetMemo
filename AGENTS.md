# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

MeetMemo (MeetMemo) is a free, open-source macOS AI meeting notetaker. It captures mic + system audio, transcribes locally through a pluggable STT engine (Apple SpeechAnalyzer or sherpa-onnx SenseVoice), and generates structured notes via the configured LLM provider.

Primary project:
- `MeetMemo/` — Native Swift/SwiftUI macOS app

## Commands

### Native App (Xcode)

Build from command line (do **not** run the app after building):
```bash
xcodebuild -project MeetMemo.xcodeproj -scheme MeetMemo -configuration Debug build
```

Release build (requires `.env` with `DEVELOPER_ID`, `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD`):
```bash
./scripts/build_release.sh
```

Version management:
```bash
./scripts/update_version.sh [major|minor|patch|build|custom]
./scripts/verify_codesigning.sh
```

## Architecture

### Native App — MVVM Layers

**Models** (`MeetMemo/Models/`)
- `Meeting.swift` — Core data model: transcript chunks + generated notes
- `NoteTemplate.swift` — 7 built-in templates + custom templates
- `Settings.swift` — LLM credentials, prompts, onboarding state

**Managers** (singletons, `MeetMemo/Managers/`)
- `AudioManager.swift` — Captures mic + optional system audio, creates per-source `STTProvider` instances via the active `STTProviderFactory` (selected from `UserDefaultsManager.sttEngine`), streams both into them, and maintains the transcript timeline
- `RecordingSessionManager.swift` — Coordinates active recording state across the app
- `LocalStorageManager.swift` — JSON persistence under the app Documents directory (`Meetings/`, `MeetingSummaries/`, `Templates/`; sandboxed builds resolve this inside the app container); uses atomic writes (temp file → replace)
- `KeychainHelper.swift` — Secure LLM credential storage in macOS Keychain
- `UserDefaultsManager.swift` — Non-sensitive settings (selected STT engine, locale, output format, etc.); also defines the `STTEngine` enum
- `DataMigrationManager.swift` — Versioned migration support for JSON data

**Providers** (`MeetMemo/Providers/`)
The pluggable STT/LLM abstraction layer.
- `ProviderProtocols.swift` — `STTProvider` / `STTProviderFactory` / `LLMProvider` protocols + `STTProviderCapabilities`
- `SpeechAnalyzerSTTProvider.swift` — STT engine ① backed by macOS 26 SpeechAnalyzer (no speaker diarization)
- `SherpaSTTProvider.swift` — STT engine ② backed by sherpa-onnx (SenseVoice-Small + Silero VAD + CAM++ speaker embedding); supports offline speaker-diarization refinement via `applyOfflineRefinement()`
- `SherpaOnnxRuntime.swift` / `SpeakerClusteringHelpers.swift` — sherpa-onnx adapter and speaker clustering
- `LLMClient.swift` — Routes Anthropic URLs to the Messages API and all other URLs to OpenAI-compatible chat completions
- `LLMProviderConfig.swift` / `STTProviderConfig.swift` — provider configuration value types

**Services** (`MeetMemo/Services/`)
- `NotesGenerator.swift` — Builds template-aware prompts and streams note content through the configured `LLMProvider`
- `MeetingStructuredExtractor.swift` / `ContextExtractorService.swift` / `FollowUpTaskExtractor.swift` / `ReminderManager.swift` — Post-meeting structured extraction, pre-meeting context, action items, reminders
- `MeetingHTMLExporter.swift` — Renders a meeting to a self-contained HTML digest
- `AudioFileTranscriber.swift` — Transcribes imported audio/video files
- `SpeechModelInstaller.swift` — SpeechAnalyzer permission + model readiness (engine ①)
- `SherpaModelManager.swift` — Downloads/verifies local sherpa-onnx model files (engine ②)
- `APIKeyValidator.swift` — Validates LLM configs
- `ErrorHandler.swift` — Centralized error handling

**ProcessTap** (`MeetMemo/ProcessTap/`)
Low-level Core Audio subsystem for tapping system/app audio without UI access. `AudioProcessController` monitors running audio apps; `ProcessTap` manages tap lifecycle.

**SherpaOnnxBridge** (`MeetMemo/SherpaOnnxBridge/`)
Auto-generated Swift bridge to the sherpa-onnx C API (`SherpaOnnx.swift`). The prebuilt xcframeworks live under `Frameworks/` (git-ignored, fetched by `scripts/fetch_sherpa_frameworks.sh`).

**ViewModels** (`MeetMemo/ViewModels/`)
SwiftUI `@Published` observable objects: `MeetingListViewModel`, `MeetingViewModel`, `SettingsViewModel`, `TemplatesViewModel`.

**Views** (`MeetMemo/Views/`)
SwiftUI views wired to ViewModels. Entry point is `ContentView.swift`; app bootstrap is in `MeetMemoApp.swift`.

### Key Data Flow

1. **Recording start** → `RecordingSessionManager` → model readiness is verified for the active engine (`SpeechModelInstaller` for SpeechAnalyzer, `SherpaModelManager` for SenseVoice) → `AudioManager` opens per-source STT streams (via the active `STTProviderFactory`) for mic and, when enabled, system audio → transcript chunks arrive and are appended to the active `Meeting` with a 2-second debounce before saving. On stop, providers flush via `awaitPendingFinalization`, and the SenseVoice engine may emit `STTTranscriptCorrection`s from an offline speaker-diarization pass.
2. **Note generation** → `NotesGenerator` reads transcript + selected `NoteTemplate` → `LLMClient` selects Anthropic Messages or OpenAI-compatible chat completions from the configured base URL → streams markdown notes back to `RenderedNotesView`
3. **Persistence** → all meetings/templates stored as JSON files in the app Documents directory; LLM credentials in Keychain

## Key Configuration

| File | Purpose |
|------|---------|
| `MeetMemo/MeetMemo.entitlements` | Sandbox permissions: audio input, screen capture, network, mach lookups |
| `MeetMemo/Info.plist` | Audio usage descriptions |
| `.env.template` | Required env vars for code signing and notarization |

## Important Constraints

- **Build without running**: When modifying the native app, build to verify compilation but do not launch the app.
- **Code signing**: The release binary requires a Developer ID Application certificate. Debug builds run unsigned locally.
- **Universal binary**: Release builds target both `arm64` and `x86_64`.
- **Conventional commits**: Follow conventional commit format (`feat:`, `fix:`, `chore:`, etc.) per `CONTRIBUTING.md`.
- **Contributor License Agreement**: All contributions grant the project rights to relicense under LGPL-3.0.
