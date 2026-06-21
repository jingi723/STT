#!/bin/bash
# meeting_stt 대시보드 원클릭 실행 (macOS)
# Finder에서 이 파일을 더블클릭하면 대시보드가 뜨고 브라우저가 자동으로 열립니다.
# (처음 실행 시 보안 경고가 나오면: 파일 우클릭 → 열기 → 열기)

cd "$(dirname "$0")" || exit 1

# 1) 가상환경 python 찾기 (mac: bin / 윈도우 호환: Scripts)
PY=""
for cand in "STT_env/bin/python" ".venv/bin/python" "venv/bin/python"; do
  if [ -x "$cand" ]; then PY="$cand"; break; fi
done

if [ -z "$PY" ]; then
  echo "❌ 가상환경(STT_env)을 찾을 수 없습니다."
  echo ""
  echo "   먼저 환경을 만드세요 (터미널):"
  echo "     uv venv STT_env --python 3.12"
  echo "     source STT_env/bin/activate"
  echo "     uv pip install -r requirements.txt"
  echo ""
  echo "엔터를 누르면 창이 닫힙니다."
  read -r _
  exit 1
fi

# 2) 의존성 간단 점검 (없으면 안내만)
if ! "$PY" -c "import fastapi, uvicorn, sounddevice" >/dev/null 2>&1; then
  echo "⚠️  대시보드 의존성이 설치되지 않았습니다 (fastapi/uvicorn/sounddevice)."
  echo "   설치: $PY -m pip install -r requirements.txt"
  echo ""
  echo "엔터를 누르면 창이 닫힙니다."
  read -r _
  exit 1
fi

# 3) 2초 뒤 브라우저 자동 오픈 후 서버 시작
echo "✅ 대시보드를 시작합니다... 곧 브라우저가 열립니다. (종료: 이 창에서 Ctrl+C)"
( sleep 2; open "http://127.0.0.1:8000" ) >/dev/null 2>&1 &
"$PY" -m meeting_stt dashboard

echo ""
echo "대시보드가 종료되었습니다. 엔터를 누르면 창이 닫힙니다."
read -r _
