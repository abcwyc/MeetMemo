# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MeetMemo (MeetMemo) is a free, open-source macOS AI meeting notetaker. It captures mic + system audio, transcribes locally through macOS SpeechAnalyzer, and generates structured notes via the configured LLM provider.

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
- `AudioManager.swift` — Captures mic + optional system audio, streams both into local SpeechAnalyzer STT providers, and maintains the transcript timeline
- `RecordingSessionManager.swift` — Coordinates active recording state across the app
- `LocalStorageManager.swift` — JSON persistence under the app Documents directory (`Meetings/`, `MeetingSummaries/`, `Templates/`; sandboxed builds resolve this inside the app container); uses atomic writes (temp file → replace)
- `KeychainHelper.swift` — Secure LLM credential storage in macOS Keychain
- `DataMigrationManager.swift` — Versioned migration support for JSON data

**Services** (`MeetMemo/Services/`)
- `NotesGenerator.swift` — Builds template-aware prompts and streams note content through the configured `LLMProvider`
- `LLMClient.swift` — Routes Anthropic URLs to the Messages API and all other URLs to OpenAI-compatible chat completions
- `APIKeyValidator.swift` — Validates LLM configs; SpeechAnalyzer readiness is handled by `SpeechModelInstaller`
- `ErrorHandler.swift` — Centralized error handling

**ProcessTap** (`MeetMemo/ProcessTap/`)
Low-level Core Audio subsystem for tapping system/app audio without UI access. `AudioProcessController` monitors running audio apps; `ProcessTap` manages tap lifecycle.

**ViewModels** (`MeetMemo/ViewModels/`)
SwiftUI `@Published` observable objects: `MeetingListViewModel`, `MeetingViewModel`, `SettingsViewModel`, `TemplatesViewModel`.

**Views** (`MeetMemo/Views/`)
SwiftUI views wired to ViewModels. Entry point is `ContentView.swift`; app bootstrap is in `MeetMemoApp.swift`.

### Key Data Flow

1. **Recording start** → `RecordingSessionManager` → `SpeechModelInstaller` verifies speech permission + local model availability → `AudioManager` opens local SpeechAnalyzer-backed STT streams for mic and, when enabled, system audio → transcript chunks arrive and are appended to the active `Meeting` with a 2-second debounce before saving
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
