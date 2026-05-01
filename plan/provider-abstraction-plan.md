# Provider Abstraction Status

This document records the current provider architecture. It replaces the original migration plan, which described an older OpenAI/MacPaw implementation and several steps that have already changed.

## Current State

- STT is abstracted behind `STTProvider` in `meetingnotes/Providers/ProviderProtocols.swift`.
- `AudioManager` receives an `STTProviderFactory` and creates separate provider instances for microphone and system audio.
- The implemented STT provider is `DoubaoSTTProvider`.
- LLM calls are abstracted behind `LLMProvider`.
- `NotesGenerator` depends on `LLMProvider` and does not construct provider-specific requests directly.
- `LLMClient` routes by `LLMProviderConfig.apiStyle`:
  - Anthropic base URLs and `/v1/messages` endpoints use the Anthropic Messages API.
  - Other base URLs use OpenAI-compatible `/chat/completions` streaming.
- Provider credentials and model settings are stored through `SettingsViewModel` and `KeychainHelper`.

## STT Implementation

Files:

- `meetingnotes/Providers/STTProviderConfig.swift`
- `meetingnotes/Providers/ProviderProtocols.swift`
- `meetingnotes/Providers/DoubaoProtocol.swift`
- `meetingnotes/Providers/DoubaoSTTProvider.swift`
- `meetingnotes/Managers/AudioManager.swift`

`DoubaoSTTProvider` connects to `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` with:

- `X-Api-App-Key`
- `X-Api-Access-Key`
- `X-Api-Resource-Id`
- `X-Api-Connect-Id`

Audio is converted to 16 kHz mono PCM before streaming. Transcript callbacks use `STTTranscriptUpdate`, which carries text, final/interim status, and optional utterance timing.

## LLM Implementation

Files:

- `meetingnotes/Providers/LLMProviderConfig.swift`
- `meetingnotes/Providers/LLMClient.swift`
- `meetingnotes/Providers/ProviderProtocols.swift`
- `meetingnotes/Services/NotesGenerator.swift`

`LLMProviderConfig.defaultBaseURL` is `https://api.anthropic.com`.

Anthropic requests:

- Endpoint: `/v1/messages`
- Header: `x-api-key`
- Header: `anthropic-version`
- Stream parser: Anthropic event stream, primarily `content_block_delta`

OpenAI-compatible requests:

- Endpoint: `/chat/completions`
- Header: `Authorization: Bearer ...`
- Stream parser: SSE `choices[].delta.content`

`LLMProviderConfig.requestURL(endpoint:)` avoids duplicating path segments, so base URLs such as `https://api.openai.com/v1`, `https://api.anthropic.com/v1`, and full chat-completions endpoints are handled correctly.

## Validation And Tests

The test target is `MeetMemoTests`.

Current provider-related tests include:

- `meetingnotesTests/LLMProviderConfigTests.swift`
- `meetingnotesTests/MeetingTranscriptFormattingTests.swift`
- `meetingnotesTests/UtteranceDiffTrackerTests.swift`

Useful command:

```bash
xcodebuild test -project Meetingnotes.xcodeproj -scheme meetingnotes -configuration Debug -destination 'platform=macOS,arch=arm64'
```

## Remaining Work

- Add a second concrete STT provider to validate that the `STTProvider` abstraction is broad enough.
- Add unit coverage for `DoubaoProtocol` frame encoding/decoding.
- Add mocked stream tests for Anthropic and OpenAI-compatible LLM parsing.
- Expand provider validation beyond connection tests where providers expose a suitable health or account endpoint.
