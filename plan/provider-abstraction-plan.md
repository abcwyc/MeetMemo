# Provider Abstraction Status

This document records the current provider architecture (STT + LLM). It reflects the
current dual-engine STT design; earlier revisions of this file described a Doubao
WebSocket STT implementation that has since been removed.

## Current State

- STT is abstracted behind `STTProvider` / `STTProviderFactory` in
  `MeetMemo/Providers/ProviderProtocols.swift`.
- `AudioManager` holds an `STTProviderFactory` chosen from `UserDefaultsManager.sttEngine`
  and creates separate provider instances for microphone and system audio. It refreshes
  the factory from settings on each recording start (`refreshSTTFactoryFromSettings`).
- Two STT engines are implemented, selected via the `STTEngine` enum
  (`UserDefaultsManager.swift`):
  - `.appleSpeechAnalyzer` → `SpeechAnalyzerSTTProvider` (macOS 26 SpeechAnalyzer).
  - `.sherpaSenseVoice` → `SherpaSTTProvider` (sherpa-onnx: SenseVoice-Small + Silero VAD
    + CAM++ speaker embedding).
- LLM calls are abstracted behind `LLMProvider`. `NotesGenerator` depends on `LLMProvider`
  and does not construct provider-specific requests directly.
- `LLMClient` routes by `LLMProviderConfig.apiStyle`:
  - Anthropic base URLs and `/v1/messages` endpoints use the Anthropic Messages API.
  - Other base URLs use OpenAI-compatible `/chat/completions` streaming.
- Provider credentials and model settings are stored through `SettingsViewModel` and
  `KeychainHelper` (sensitive) / `UserDefaultsManager` (non-sensitive).

## STT Implementation

Files:

- `MeetMemo/Providers/ProviderProtocols.swift` — `STTProvider`, `STTProviderFactory`,
  `LLMProvider` protocols; `STTProviderCapabilities`; `STTTranscriptCorrection`.
- `MeetMemo/Providers/SpeechAnalyzerSTTProvider.swift` — SpeechAnalyzer engine.
  No speaker diarization (`supportsCorrections: false`).
- `MeetMemo/Providers/SherpaSTTProvider.swift` — SenseVoice engine. Two-stage speaker
  labeling: online centroid clustering during recording, then offline complete-linkage
  HAC re-clustering on stop, emitted as `STTTranscriptCorrection`s via
  `applyOfflineRefinement()`.
- `MeetMemo/Providers/SherpaOnnxRuntime.swift` — sherpa-onnx runtime adapter.
- `MeetMemo/Providers/SpeakerClusteringHelpers.swift` — clustering helpers.
- `MeetMemo/Providers/STTProviderConfig.swift` — STT configuration (`locale`, `engine`).
- `MeetMemo/Managers/AudioManager.swift` — Uses the injected factory to run mic + system STT.
- `MeetMemo/Services/SpeechModelInstaller.swift` — readiness for the SpeechAnalyzer engine.
- `MeetMemo/Services/SherpaModelManager.swift` — downloads/verifies local sherpa-onnx models.

## LLM Implementation

Files:

- `MeetMemo/Providers/LLMClient.swift` — Anthropic + OpenAI-compatible streaming.
- `MeetMemo/Providers/LLMProviderConfig.swift` — `apiStyle`, URL building, validation.
- `MeetMemo/Services/NotesGenerator.swift` — Talks to `LLMProvider` only.
