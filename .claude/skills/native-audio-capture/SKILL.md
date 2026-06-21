---
name: native-audio-capture
description: macOS에서 특정 앱(프로세스)의 오디오만 캡처하는 네이티브 헬퍼(Swift, Core Audio Process Tap)를 구현/수정할 때 사용. native/apptap.swift 빌드, 앱 목록 열거, 앱별 녹음, Python 연동 작업 시 반드시 이 스킬을 따른다.
---

# Native Audio Capture (앱별 캡처) 스킬

macOS는 앱이 시스템/다른 앱의 출력 오디오를 직접 못 잡게 막는다(보안). `sounddevice`(PortAudio)는 "장치"만 보므로 앱별 캡처가 불가능하다. 해결책은 **Core Audio Process Tap**(macOS 14.2+)을 쓰는 작은 Swift 헬퍼를 만들어 Python이 서브프로세스로 호출하는 것.

## 왜 Core Audio Process Tap인가
- ScreenCaptureKit도 가능하지만 "화면 녹화" 권한 의미가 강하고 오디오 단독엔 과함.
- Process Tap은 오디오 전용 API. 특정 프로세스를 탭해 집합 장치(aggregate device)로 IOProc로 받아 wav로 쓴다.
- `muteBehavior = .unmuted`로 두면 **사용자는 그대로 들으면서** 캡처된다(라우팅 불필요 — BlackHole 대비 핵심 장점).

## 헬퍼 인터페이스 (Python이 의존 — 고정)
바이너리 `native/apptap`:
- `apptap list` — JSON 배열 출력: `[{"pid","name","bundleID"}]` (오디오 객체로 잡히는 프로세스).
- `apptap record --pid N --out FILE.wav` — 해당 PID 오디오를 wav로 녹음. **SIGINT/SIGTERM 받으면 파일을 정상 종료(finalize)** 후 종료. (서버가 start=프로세스 시작, stop=SIGTERM로 제어)

## 빌드
```bash
swiftc -O native/apptap.swift -o native/apptap \
  -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit
```
- 산출물 `native/apptap`(arm64). 소스 변경 시 재빌드. 빌드 검증은 `apptap list`가 JSON을 내는지로 확인.

## 권한 (TCC)
- 첫 `record` 시 macOS가 "오디오 녹음" 권한을 요청하거나, 미허용 시 `AudioHardwareCreateProcessTap`가 실패한다.
- CLI 바이너리는 권한 대화가 안 뜰 수 있다 → 시스템 설정 > 개인정보 보호 > (오디오 녹음/화면 기록)에 터미널 또는 이 바이너리를 추가하도록 **에러 메시지로 안내**한다. 코드로 우회하지 않는다.

## Python 연동 (capture.py)
- `list_app_sources()` → `apptap list` 실행해 JSON 파싱. 바이너리 없으면 빈 목록 + 안내.
- `AppRecorder` → `apptap record`를 `subprocess.Popen`으로 시작(start), `terminate()`(SIGTERM)로 정지(stop). 출력 wav 경로 반환.
- 바이너리 경로는 `meeting_stt/../native/apptap`(프로젝트 루트 기준). 없으면 명확한 빌드 안내.

## 대시보드 연동
- 소스 종류 선택: "마이크/장치"(sounddevice) vs "앱"(apptap). 앱 선택 시 `apptap list`로 앱 드롭다운 구성.
- 녹음 흐름은 동일(start/stop). 전사 파이프라인은 그대로 재사용.

## 구현 주의
- 탭 포맷(`kAudioTapPropertyFormat`)은 Float32. ExtAudioFile client format=탭 포맷, file format=WAV(Int16)로 변환 저장.
- IOProc 안에서는 `ExtAudioFileWriteAsync`(실시간 안전)만 호출. 할당·로그 금지.
- 종료 시 역순 정리: stop IOProc → destroy IOProcID → destroy aggregate device → destroy process tap → dispose ExtAudioFile.
