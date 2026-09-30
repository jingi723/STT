#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d /tmp/stt-recording-tests.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
  macos/Sources/MeetingSTTApp/{SessionStore,DeviceRecorder,ProcessRunner,RecordingMixer}.swift \
  tests/RecordingMixerTests.swift -o "$TEST_DIR/recording-tests"
"$TEST_DIR/recording-tests" "$@"
