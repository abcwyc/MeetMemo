<div align="center">
  <!-- REMOVE THIS IF YOU DON'T HAVE A LOGO -->
    <img src="https://github.com/user-attachments/assets/309577e8-94db-431f-b8df-a53a763b4c87" alt="Logo" width="80" height="80">

<h3 align="center">MeetMemo</h3>

  <p align="center">
    The Free, Open-Source AI Notetaker for Busy Engineers
    <br />
     <a href="https://github.com/abcwyc/MeetMemo/releases/latest/download/MeetMemo.dmg">Download for macOS 15+</a>
  </p>
</div>

## Recall.ai - Meeting Transcription API

MeetMemo runs locally, capturing two streams: system & mic.

If you’re looking for a transcription API for meetings, consider checking out [Recall.ai](
https://www.recall.ai?utm_source=github&utm_medium=sponsorship&utm_campaign=abcwyc+MeetMemo), an API that works with Zoom, Google Meet, Microsoft Teams, and more. Recall.ai diarizes by pulling the speaker data and separate audio streams from the meeting platforms, which means 100% accurate speaker diarization with actual speaker names.

## Demo

https://github.com/user-attachments/assets/cadd4504-e9d9-4ccd-874d-41d8a84f4c9d

## Features

Implemented:

- Recording mic & system audio
- Live transcript
- Ability to also write down additional notes
- AI generated enhanced notes
- Copy functionality
- Meeting deletion functionality
- Meeting search functionality
- Ability to edit the system prompt
- Configure STT credentials and LLM API key/base URL/model
- Anthropic Messages API and OpenAI-compatible chat completions for note generation
- Auto updates
- Text formatting
- Different note templates
- Integrate with PostHog for anonymous analytics (installs, opens, meetings created)
- Onboarding screen to enable settings and configure providers

Todo:

- add padding to text inputs
- add confirmation when clicking the copy button
- add broader provider health checks beyond the current connection tests

Later:

- Cool recording indicator (dancing bars)
- Connecting to your Google calendar
- AI chat for asking questions about a meeting
- Additional STT provider implementations beyond the current Doubao provider
- Integrations for email, Slack, Notion, etc.

## Local Development

Open the project in Xcode. Command+R to build it and run it.

## Releasing a New Version

Follow these steps to create a new release with auto-updates:

### Prerequisites

- Homebrew packages: `brew install create-dmg sparkle`
- Make scripts executable: `chmod +x scripts/update_version.sh scripts/build_release.sh`

### Release Process

1. **Update the version number:**

   ```bash
   # For bug fixes (1.0 → 1.0.1):
   ./scripts/update_version.sh patch

   # For new features (1.0 → 1.1):
   ./scripts/update_version.sh minor

   # For major changes (1.0 → 2.0):
   ./scripts/update_version.sh major

   # For custom version:
   ./scripts/update_version.sh custom 1.2.0
   ```

2. **Build the release:**

   ```bash
   ./scripts/build_release.sh
   ```

   This will:

   - Clean build the app in Release mode
   - Create a signed DMG file
   - Generate the appcast.xml for auto-updates

3. **Create GitHub Release:**

   - Go to [GitHub Releases](https://github.com/abcwyc/MeetMemo/releases)
   - Click "Create a new release"
   - Tag: `v1.0.1` (match the version number)
   - Title: `MeetMemo v1.0.1`
   - Upload the DMG and zip files from `releases/` folder
   - Generate release notes

4. **Update appcast:**

   ```bash
   git add appcast.xml
   git commit -m "Update appcast for v1.0.1"
   git push
   ```
