#!/bin/bash
# Build and set up Meeting STT on macOS.
# Usage: bash build.sh [all|prereqs|deps|apptap|app|icon|models]
# all: Python environment, helper, app, icons, and model downloads.
set -e
cd "$(dirname "$0")"
PY=STT_env/bin/python
log(){ printf "\n▶ %s\n" "$1"; }

check_prereqs(){
  log "Checking prerequisites"
  # Homebrew
  if ! command -v brew >/dev/null; then
    echo "  ⚠ Homebrew is missing. Install it from https://brew.sh and try again."
  fi
  # Python 3.12
  if ! command -v python3.12 >/dev/null && [ ! -x /opt/homebrew/bin/python3.12 ]; then
    if command -v brew >/dev/null; then echo "  python@3.12 Installing..."; brew install python@3.12; else echo "  ⚠ Python 3.12 is required"; fi
  else echo "  Python 3.12 OK"; fi
  # ffmpeg
  if ! command -v ffmpeg >/dev/null; then
    if command -v brew >/dev/null; then echo "  Installing ffmpeg..."; brew install ffmpeg; else echo "  ⚠ ffmpeg is required"; fi
  else echo "  ffmpeg OK"; fi
  # Xcode Command Line Tools are required for native audio capture.
  if command -v swiftc >/dev/null; then echo "  swiftc OK"; else echo "  ⚠ swiftc is missing; run 'xcode-select --install' (required for audio capture)"; fi
  # Hugging Face token
  if [ -n "$HF_TOKEN" ] || { [ -f .env ] && grep -q '^HF_TOKEN=' .env; }; then echo "  HF_TOKEN OK"; else
    echo "  ⚠ HF token is missing: 'cp .env.example .env' and enter your token (needed to download models)"; fi
}

setup_deps(){
  log "Python environment and dependencies"
  if [ ! -x "$PY" ]; then
    P312="$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)"
    [ -x "$P312" ] || { echo "  ✗ Python 3.12 was not found. Install it first."; exit 1; }
    "$P312" -m venv STT_env
  fi
  "$PY" -m pip install -q --upgrade pip
  "$PY" -m pip install -q -r requirements.txt
  echo "  Dependencies OK"
}

build_apptap(){
  log "Building audio capture helper (Core Audio Process Tap)"
  command -v swiftc >/dev/null || { echo "  ⚠ swiftc is missing (Xcode Command Line Tools required); skipping"; return 0; }
  PLIST="$(mktemp /tmp/apptap_plist.XXXXXX)"
  cat > "$PLIST" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.meetingstt.apptap</string>
  <key>CFBundleName</key><string>apptap</string>
  <key>CFBundleExecutable</key><string>apptap</string>
  <key>NSAudioCaptureUsageDescription</key><string>Record app or system audio for meeting transcription.</string>
  <key>NSMicrophoneUsageDescription</key><string>Record audio for meeting transcription.</string>
</dict></plist>
PLISTEOF
  swiftc -O native/apptap.swift -o native/apptap \
    -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"
  codesign -s - --force native/apptap
  rm -f "$PLIST"
  echo "  apptap OK ($(pwd)/native/apptap)"
}

build_app(){
  log "Building SwiftUI app"
  command -v swift >/dev/null || { echo "  ✗ swift is missing. Run 'xcode-select --install' and try again."; exit 1; }
  command -v swiftc >/dev/null || { echo "  ✗ swiftc is missing. Run 'xcode-select --install' and try again."; exit 1; }

  local APP="Meeting STT.app"
  local MACOS="$APP/Contents/MacOS"
  local RESOURCES="$APP/Contents/Resources"
  swift build --package-path macos -c release
  mkdir -p "$MACOS" "$RESOURCES"
  rm -f "$MACOS/stt-launch"
  install -m 755 macos/.build/release/MeetingSTTApp "$MACOS/MeetingSTTApp"
  cp assets/stt-icon.icns "$RESOURCES/icon.icns"
  codesign --force --deep --sign - "$APP"
  touch "$APP"
  echo "  App OK ($(pwd)/$APP)"
}

apply_icon(){
  log "Applying launcher icon"
  local ICNS="assets/stt-icon.icns" TARGET="Meeting STT.command"
  [ -f "$ICNS" ] && [ -f "$TARGET" ] || { echo "  ⚠ Icon or launcher missing; skipping"; return 0; }
  local tmp; tmp="$(mktemp -d)"
  cp "$ICNS" "$tmp/i.icns"
  sips -i "$tmp/i.icns" >/dev/null
  DeRez -only icns "$tmp/i.icns" > "$tmp/i.rsrc"
  Rez -append "$tmp/i.rsrc" -o "$TARGET"
  SetFile -a C "$TARGET"
  rm -rf "$tmp"
  echo "  Icon OK"
}

download_models(){
  log "Downloading models (Qwen3-ASR and speaker diarization)"
  if [ -z "$HF_TOKEN" ] && ! { [ -f .env ] && grep -q '^HF_TOKEN=' .env; }; then
    echo "  ⚠ HF token is missing. Run 'cp .env.example .env', set your token, then run 'bash build.sh models'."
    return 0
  fi
  "$PY" scripts/download_models.py
}

case "${1:-all}" in
  deps)   setup_deps ;;
  apptap) build_apptap ;;
  app)    build_app ;;
  icon)   apply_icon ;;
  models) download_models ;;
  prereqs) check_prereqs ;;
  all)    check_prereqs; setup_deps; build_apptap; apply_icon; build_app; download_models
          log "Done. Open 'Meeting STT.app' to get started." ;;
  *) echo "Usage: bash build.sh [all|prereqs|deps|apptap|app|icon|models]"; exit 2 ;;
esac
