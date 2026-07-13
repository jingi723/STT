#!/bin/bash
# meeting_stt 빌드/셋업 — 한 파일로 통합 (macOS)
#   venv·의존성 · ffmpeg 확인 · 앱캡처 헬퍼(apptap) 빌드 · 모델 다운로드 · 런처 아이콘 적용
#
# 사용:
#   bash build.sh           # 전체 (처음 셋업)
#   bash build.sh deps      # venv + 의존성만
#   bash build.sh apptap    # 앱캡처 헬퍼만 빌드
#   bash build.sh app       # SwiftUI 앱만 빌드
#   bash build.sh icon      # 런처 아이콘만 재적용
#   bash build.sh models    # 모델만 다운로드 (.env 의 HF_TOKEN 필요)
set -e
cd "$(dirname "$0")"
PY=STT_env/bin/python
log(){ printf "\n▶ %s\n" "$1"; }

check_prereqs(){
  log "사전 준비물 점검"
  # Homebrew
  if ! command -v brew >/dev/null; then
    echo "  ⚠ Homebrew 없음 → https://brew.sh 에서 설치 후 다시 실행하세요."
  fi
  # Python 3.12
  if ! command -v python3.12 >/dev/null && [ ! -x /opt/homebrew/bin/python3.12 ]; then
    if command -v brew >/dev/null; then echo "  python@3.12 설치..."; brew install python@3.12; else echo "  ⚠ Python 3.12 필요"; fi
  else echo "  Python 3.12 OK"; fi
  # ffmpeg
  if ! command -v ffmpeg >/dev/null; then
    if command -v brew >/dev/null; then echo "  ffmpeg 설치..."; brew install ffmpeg; else echo "  ⚠ ffmpeg 필요"; fi
  else echo "  ffmpeg OK"; fi
  # Xcode CLT (swiftc) — 앱오디오 캡처용. 없으면 안내만(자동설치 불가)
  if command -v swiftc >/dev/null; then echo "  swiftc OK"; else echo "  ⚠ swiftc 없음 → 'xcode-select --install' (앱 오디오 캡처에 필요)"; fi
  # HF 토큰
  if [ -n "$HF_TOKEN" ] || { [ -f .env ] && grep -q '^HF_TOKEN=' .env; }; then echo "  HF_TOKEN OK"; else
    echo "  ⚠ HF 토큰 없음 → 'cp .env.example .env' 후 토큰 입력 (모델 다운로드에 필요)"; fi
}

setup_deps(){
  log "venv + 의존성"
  if [ ! -x "$PY" ]; then
    P312="$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)"
    [ -x "$P312" ] || { echo "  ✗ Python 3.12를 찾을 수 없습니다. 먼저 설치하세요."; exit 1; }
    "$P312" -m venv STT_env
  fi
  "$PY" -m pip install -q --upgrade pip
  "$PY" -m pip install -q -r requirements.txt
  echo "  의존성 OK"
}

build_apptap(){
  log "앱캡처 헬퍼(apptap) 빌드 — Core Audio Process Tap"
  command -v swiftc >/dev/null || { echo "  ⚠ swiftc 없음(Xcode CLT 필요) → 건너뜀"; return 0; }
  PLIST="$(mktemp /tmp/apptap_plist.XXXXXX)"
  cat > "$PLIST" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.meetingstt.apptap</string>
  <key>CFBundleName</key><string>apptap</string>
  <key>CFBundleExecutable</key><string>apptap</string>
  <key>NSAudioCaptureUsageDescription</key><string>회의 오디오 전사를 위해 선택한 앱의 오디오를 녹음합니다.</string>
  <key>NSMicrophoneUsageDescription</key><string>회의 오디오 전사를 위해 오디오를 녹음합니다.</string>
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
  log "SwiftUI 앱 빌드"
  command -v swift >/dev/null || { echo "  ✗ swift 없음 → 'xcode-select --install' 후 다시 실행하세요."; exit 1; }
  command -v swiftc >/dev/null || { echo "  ✗ swiftc 없음 → 'xcode-select --install' 후 다시 실행하세요."; exit 1; }

  local APP="STT실행.app"
  local MACOS="$APP/Contents/MacOS"
  local RESOURCES="$APP/Contents/Resources"
  swift build --package-path macos -c release
  mkdir -p "$MACOS" "$RESOURCES"
  rm -f "$MACOS/stt-launch"
  install -m 755 macos/.build/release/MeetingSTTApp "$MACOS/MeetingSTTApp"
  cp assets/stt-icon.icns "$RESOURCES/icon.icns"
  codesign --force --deep --sign - "$APP"
  touch "$APP"
  echo "  앱 OK ($(pwd)/$APP)"
}

apply_icon(){
  log "런처 아이콘 적용"
  local ICNS="assets/stt-icon.icns" TARGET="STT실행.command"
  [ -f "$ICNS" ] && [ -f "$TARGET" ] || { echo "  ⚠ 아이콘/런처 없음 → 건너뜀"; return 0; }
  local tmp; tmp="$(mktemp -d)"
  cp "$ICNS" "$tmp/i.icns"
  sips -i "$tmp/i.icns" >/dev/null
  DeRez -only icns "$tmp/i.icns" > "$tmp/i.rsrc"
  Rez -append "$tmp/i.rsrc" -o "$TARGET"
  SetFile -a C "$TARGET"
  rm -rf "$tmp"
  echo "  아이콘 OK"
}

download_models(){
  log "모델 다운로드 (Qwen3-ASR + 화자분리 미러)"
  if [ -z "$HF_TOKEN" ] && ! { [ -f .env ] && grep -q '^HF_TOKEN=' .env; }; then
    echo "  ⚠ HF 토큰이 없어 건너뜀. 'cp .env.example .env'로 토큰 설정 후 'bash build.sh models' 실행."
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
          log "완료 — 'STT실행.app' 더블클릭으로 실행" ;;
  *) echo "사용: bash build.sh [all|prereqs|deps|apptap|app|icon|models]"; exit 2 ;;
esac
