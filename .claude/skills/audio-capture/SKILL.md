---
name: audio-capture
description: 오프라인 오디오 캡처(입력 장치 열거·선택, start/stop 녹음, wav 저장)를 구현/수정할 때 사용. capture.py, sounddevice 기반 녹음, 마이크 및 시스템/앱 오디오(BlackHole) 장치 선택 작업 시 반드시 이 스킬을 따른다.
---

# Audio Capture 구현 스킬

`meeting_stt/capture.py` — 백엔드에서 오디오를 캡처한다. 브라우저가 아니라 Python(`sounddevice`/PortAudio)이 녹음하므로, 마이크뿐 아니라 **시스템/앱 오디오도 입력 장치로 선택**할 수 있다.

## 왜 백엔드 캡처인가
브라우저 `getUserMedia`는 마이크만, 시스템 오디오는 화면공유 권한이 필요하고 "오프라인 앱 오디오"를 못 잡는다. `sounddevice`는 OS의 모든 입력 장치를 열거하므로, BlackHole 같은 가상 입력장치를 깔면 시스템/앱 오디오도 일반 장치처럼 선택된다.

## macOS 시스템 오디오 = BlackHole (필수 안내)
- macOS는 앱이 시스템 오디오를 직접 캡처하지 못한다(보안). 우회 불가.
- 무료 가상 장치 **BlackHole**(`brew install blackhole-2ch`)를 설치하면 입력 장치 목록에 나타난다.
- 시스템 소리를 들으면서 녹음하려면 macOS "Audio MIDI 설정"에서 다중출력장치(스피커+BlackHole)를 만들어 출력으로 지정한다.
- 코드로 우회하지 말고, 장치 목록·문서·에러로 안내한다.

## import-safe 원칙
`sounddevice`/`numpy`는 함수·메서드 내부에서 지연 import한다. `import meeting_stt.capture`만으로 PortAudio를 열거나 장치를 점유하면 안 된다(테스트·CLI가 무거워지고, 미설치 환경에서 import가 깨짐).

## 공개 API (dashboard-engineer가 의존 — 시그니처 고정)
```python
def list_input_devices() -> list[dict]:
    # [{"index","name","channels","default_samplerate"}] — max_input_channels>0 만
class Recorder:
    def __init__(self, device=None, samplerate=None, channels=1): ...
    def start(self) -> None        # sd.InputStream 콜백으로 프레임 누적 (논블로킹)
    def stop(self, out_path) -> str  # 스트림 종료, 프레임 concat → soundfile로 wav 저장, 경로 반환
    @property
    def is_recording(self) -> bool
```

## 구현 지침
- 샘플레이트: `samplerate=None`이면 선택 장치의 `default_samplerate` 사용. 모노 저장(`channels=1`).
- 녹음 프레임은 콜백에서 `indata.copy()`로 리스트에 append. stop에서 `numpy.concatenate`.
- 빈 녹음(stop인데 프레임 0)도 에러 없이 빈 wav 또는 명확한 메시지로 처리.
- wav 저장은 `meeting_stt.audio.write_wav` 재사용(soundfile import 보장 — NameError 회귀 방지).
- 장치 미지원 설정은 `sounddevice.PortAudioError`를 잡아 "이 장치는 X Hz/모노를 지원하지 않습니다"로 안내.

## 산출물 경로
녹음 wav는 `outputs/recordings/{timestamp}.wav` 권장. timestamp는 호출측(서버)에서 주입(스크립트 내 Date.now류 금지 — 서버가 생성).
