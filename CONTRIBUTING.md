# Contributing

Use `main` for the English public version and open changes against that branch. The maintainer uses `personal/ko` for the Korean app; do not merge language changes from that branch into `main`.

Keep shared behavior changes separate from translation commits so they can be cherry-picked between branches. Keep user-facing messages, CLI help, and generated note templates in English on `main`. Do not translate user transcripts or names.

Before proposing a change:

```bash
bash build.sh apptap
bash build.sh app
bash scripts/test-recording.sh
python3 tests/test_ai_notes.py
python3 tests/test_english.py
python3 -m compileall -q meeting_stt scripts
git diff --check
```

Use synthetic audio and temporary directories for tests. Do not include recordings, transcripts, credentials, Python environments, or model weights in commits. Live recording and model inference are separate, environment-dependent checks; report them separately from automated tests.

Describe the behavior changed, how it was tested, and any remaining limits. See the license section of the README before reusing or redistributing the project.
