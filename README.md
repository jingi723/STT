# Meeting STT

Record meetings on your Mac, transcribe them locally, and turn the transcript into meeting notes.

Meeting STT combines **system audio and your microphone** without asking you to identify app processes or PIDs. A native SwiftUI app handles recording, playback, and saved sessions; Qwen3-ASR-1.7B and pyannote handle transcription and speaker diarization.

**macOS 14.2+ · Apple Silicon recommended · English interface**

This is the English public branch. The maintainer's Korean version is preserved on [`personal/ko`](https://github.com/jingi723/STT/tree/personal/ko). Interface language does not change the language spoken in your recordings or translate your transcripts.

## What you can do

- Record system audio and a microphone together, or record either source separately.
- Record a specific app when you need to exclude other playback.
- Watch elapsed time, file size, and audio levels while recording.
- Replay, rename, and transcribe saved sessions after restarting the app.
- Identify speakers with pyannote and improve recognition with context keywords.
- Search transcripts, copy results, and receive a notification when transcription finishes.
- Generate local Markdown notes, prepare an AI summary prompt, or optionally create notes with Claude CLI.

## Quick start

This repository currently ships **source**, not a standalone installer. The app uses a Python environment, models, and the audio helper inside the checkout. Keep the app beside those files.

### Requirements

- macOS 14.2 or later; Apple Silicon recommended
- [Homebrew](https://brew.sh)
- Python 3.12 and ffmpeg
- Xcode Command Line Tools (`swift`, `swiftc`)
- Several GB of disk space for models and dependencies
- A [Hugging Face read token](https://huggingface.co/settings/tokens) for model setup

```bash
xcode-select --install  # if Command Line Tools are not installed
brew install python@3.12 ffmpeg

git clone https://github.com/jingi723/STT.git
cd STT
cp .env.example .env
# Edit .env and set HF_TOKEN to your own token.

bash build.sh all
open "Meeting STT.app"
```

The build script checks prerequisites, creates `STT_env`, installs Python dependencies, builds the Core Audio helper and SwiftUI app, signs them locally, and downloads the models. The app is ad-hoc signed, not Developer ID signed or notarized.

### Permissions

Allow **Microphone** access for microphone recording and **Screen & System Audio Recording** access for system/app audio. Manage permissions in **System Settings → Privacy & Security** for Meeting STT or the terminal running it. Quit and reopen the app after changing permissions.

### Record your first meeting

1. Open `Meeting STT.app`.
2. Keep **System + Microphone** selected and choose your microphone.
3. Click **Start recording**. Use **Pause** and **Resume recording** for breaks; paused time is left out of the recording.
4. Click **Stop recording** to save and combine both tracks.
5. Select the saved session and click **Start transcription**.
6. Generate meeting notes or copy the transcript when it is ready.

| Source | Captures | Notes |
|---|---|---|
| System + Microphone (default) | All Mac playback plus the selected microphone | No app/PID selection; creates one combined WAV |
| Input device | Selected microphone or audio input | Initially selects the macOS default input |
| System audio | All Mac playback | Does not include microphone input |
| App audio | One selected app process | Useful when other app audio should be excluded |

System capture includes notification sounds and music from other apps. Headphones help avoid speaker audio being recorded again through your microphone. The app does not perform acoustic echo cancellation.

Both original tracks are retained. Their first audio-frame timestamps align the combined recording, and ffmpeg converts them to a 48 kHz mono WAV. If there is no system playback, the system track is treated as silence.

If the selected microphone disconnects while recording (for example, AirPods dropping out), recording continues from the macOS default input device and switches back when the microphone reconnects. Time with no input device attached is written as silence, so the single microphone track stays aligned with system audio. The recording panel shows a warning while this is happening.

## Local data and optional AI

Recordings, models, transcripts, and notes stay in local directories excluded from Git. Recording and speech inference run locally after model setup. No cloud speech service is required.

**AI notes is optional:** it invokes your signed-in Claude CLI and sends the transcript and prompt to that service. Local notes and prompt generation do not call an AI service. Review prompts before sharing them with an external tool.

```text
outputs/
├── recordings/{session-id}/
│   ├── audio.wav         # combined recording used for playback/transcription
│   ├── microphone.wav    # original microphone track in combined mode
│   ├── system.wav        # original system track in combined mode
│   └── metadata.json
├── {session-id}.json      # transcript with speakers and timestamps
├── {session-id}.md        # transcript and meeting notes
├── {session-id}.partial.json
└── {session-id}.prompt.md
```

Do not commit `.env`, recordings, transcripts, downloaded models, or personal wiki content. A repository checkout is needed at runtime; moving just the app to `/Applications` does not install its Python environment or models.

## Command line

```bash
STT_env/bin/python -m meeting_stt --help
STT_env/bin/python -m meeting_stt devices
STT_env/bin/python -m meeting_stt apps

# Transcribe audio with speaker diarization.
STT_env/bin/python -m meeting_stt transcribe meeting.wav \
  --context "Project Atlas, Qwen3-ASR, Alex" --num-speakers 3

# Generate local notes or an AI summary prompt.
STT_env/bin/python -m meeting_stt notes outputs/meeting.json --project Atlas
STT_env/bin/python -m meeting_stt notes outputs/meeting.json --prompt-only

# Optional: generate AI notes using your signed-in Claude CLI account.
STT_env/bin/python -m meeting_stt notes outputs/meeting.json --ai

# Run transcription and notes generation together.
STT_env/bin/python -m meeting_stt run meeting.wav --num-speakers 3

# Create a reference wiki, preserving existing files.
STT_env/bin/python -m meeting_stt init-wiki ./LLM-Wiki --project Atlas

# Preview recording cleanup; add --yes to delete WAV files, keeping text.
STT_env/bin/python -m meeting_stt clean-audio
```

The optional legacy web dashboard runs with `STT_env/bin/python -m meeting_stt dashboard` at <http://127.0.0.1:8000>. It supports input, system, and app capture individually. Combined system + microphone recording is available in the native app.

## Build and test

```bash
bash build.sh prereqs     # check setup
bash build.sh deps        # install Python dependencies
bash build.sh apptap      # build/sign the Core Audio helper
bash build.sh app         # build/sign Meeting STT.app
bash build.sh models      # download/cache models

bash scripts/test-recording.sh
python3 tests/test_ai_notes.py
python3 tests/test_english.py
python3 -m compileall -q meeting_stt scripts
```

The recording tests exercise different sample rates, start-time alignment in both directions, overlapping audio, trailing audio, silence, failure handling, input-device changes mid-recording, and child processes that exit immediately. They use a standalone Swift test runner so full Xcode is not required. Add `--live` to play a quiet test tone and save a five-second system/microphone test session. Hardware tests need the corresponding macOS permissions; a silent microphone track is not proof of voice capture.

## Troubleshooting

- **No microphone signal:** check the selected device, its mute state, and macOS microphone permission. Refresh input devices.
- **No system signal:** play some audio and check system audio recording permission. Rebuild the helper with `bash build.sh apptap` if needed.
- **Project root not found:** keep the app at the repository root, or launch it with `MEETING_STT_ROOT="$PWD" "./Meeting STT.app/Contents/MacOS/MeetingSTTApp"`.
- **Python or models missing:** run `bash build.sh deps` and `bash build.sh models`.
- **AI notes unavailable:** install and sign in to Claude CLI, or use local notes. AI errors fall back to the local template.

## Project structure

| Path | Purpose |
|---|---|
| `macos/Sources/MeetingSTTApp/` | Native recording, playback, sessions, and worker lifecycle |
| `native/apptap.swift` | Core Audio Process Tap helper |
| `meeting_stt/` | Python transcription, diarization, notes, CLI, and web dashboard |
| `scripts/` and `tests/` | Setup and regression tests |
| `outputs/` | Local user data; excluded from Git |

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and branch conventions. Historical notebooks and internal agent guides may contain Korean; the public app, CLI, dashboard, and generated note templates use English.

## License

No open-source license has been selected for this repository yet. The repository is publicly viewable, but no additional reuse or redistribution license is granted here. Models and dependencies have their own licenses.
