#!/bin/bash
# Start the optional local web dashboard from Finder.
cd "$(dirname "$0")" || exit 1
PY=""
for candidate in "STT_env/bin/python" ".venv/bin/python" "venv/bin/python"; do
  if [ -x "$candidate" ]; then PY="$candidate"; break; fi
done
if [ -z "$PY" ]; then
  echo "Python environment not found. Run: bash build.sh deps"
  read -r -p "Press Return to close." _
  exit 1
fi
if ! "$PY" -c "import fastapi, uvicorn, sounddevice" >/dev/null 2>&1; then
  echo "Dashboard dependencies are missing. Run: bash build.sh deps"
  read -r -p "Press Return to close." _
  exit 1
fi
echo "Starting the local dashboard. Press Ctrl+C to stop."
( sleep 2; open "http://127.0.0.1:8000" ) >/dev/null 2>&1 &
"$PY" -m meeting_stt dashboard
read -r -p "Dashboard stopped. Press Return to close." _
