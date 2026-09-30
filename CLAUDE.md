# Meeting STT development

Native SwiftUI macOS app for local meeting capture, Qwen3-ASR-1.7B transcription, pyannote speaker diarization, and Markdown notes.

## Branches

- `main`: English public app, CLI, dashboard, documentation, and note templates.
- `personal/ko`: maintainer's Korean version. Preserve Korean UI and output there.
- Separate shared behavior changes from language changes; cherry-pick shared fixes as needed.

## Architecture

- `macos/Sources/MeetingSTTApp/`: SwiftUI interface, sessions, recording, playback, child processes.
- `native/apptap.swift`: Core Audio Process Tap helper for app/system output (macOS 14.2+).
- `meeting_stt/`: Python worker and CLI. Use Qwen3-ASR-1.7B only; do not introduce Whisper.
- `build.sh`: environment setup, helper/app build, model downloads, signing.
- `Meeting STT.app`: built app lives next to the repository's Python environment and models.

Default capture is system audio plus microphone. Preserve `microphone.wav` and `system.wav`, align their first-frame host timestamps, and publish `audio.wav` only after successful mixing. Session metadata lives in `outputs/recordings/{session-id}/metadata.json`. Keep this disk contract compatible with the Python worker.

Request macOS audio permissions through normal APIs. Never bypass TCC. Do not expose PID selection in the default recording path. Keep expensive file reads and worker tasks off the main actor.

## Validation

Run the relevant build and regression checks documented in README.md. Use `scripts/test-recording.sh` for deterministic mixing tests without XCTest; `--live` additionally captures real hardware audio. Report untested voice capture, UI, or model inference explicitly.

The legacy `.claude/skills/` guides provide historical workflow context. Native SwiftUI is the primary UI; do not revert it to the older web-only architecture. When their team orchestration tools are unavailable, implement and verify directly.

## Data

`.env`, models, virtual environments, `outputs/`, and personal wiki files are local runtime data excluded from Git. Never publish them. Optional AI notes use Claude CLI and an external service; do not claim all notes generation is offline.
