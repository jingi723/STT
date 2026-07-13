# Meeting STT

macOS에서 회의 오디오를 녹음하고, 로컬 모델로 화자별 전사와 회의록 초안을 만드는 도구입니다.

- 네이티브 SwiftUI 앱에서 입력 장치, 시스템 출력 또는 특정 앱 오디오를 녹음합니다.
- Qwen3-ASR-1.7B로 음성을 전사하고 pyannote로 화자를 분리합니다.
- 녹음, 전사 JSON, Markdown 회의록을 로컬 디스크에 보관합니다.
- 기존 Python CLI와 로컬 웹 대시보드도 계속 사용할 수 있습니다.

> 지원 대상: macOS 14.2 이상. 모델 다운로드에는 Hugging Face 연결이 필요하지만, 다운로드가 끝난 뒤 녹음과 추론은 로컬에서 실행됩니다.

## 주요 기능

- Core Audio 입력 장치 녹음
- macOS Core Audio Process Tap 기반 시스템 전체 출력 녹음
- 프로세스를 선택하는 특정 앱 오디오 녹음
- 녹음 중 파일 크기, 경과 시간, 실시간 레벨 표시
- 저장된 세션 재생, 이름 변경, 삭제 및 앱 재실행 후 복구
- Qwen3-ASR context biasing
- pyannote 화자분리와 화자 수 지정
- 중간 결과 저장과 중단된 전사 이어하기
- 로컬 회의록 템플릿 또는 AI 에이전트용 요약 프롬프트 생성

## 구성

```text
SwiftUI macOS 앱
├── 녹음·재생·세션 관리
├── 입력 장치 / 시스템 출력 / 앱 오디오 선택
└── Python worker와 native/apptap 실행
          │
          ├── native/apptap
          │   └── Core Audio Process Tap → WAV
          │
          └── meeting_stt Python 패키지
              ├── Qwen3-ASR-1.7B
              ├── pyannote diarization
              └── transcript / notes / prompt
```

Swift 앱과 Python 사이에 별도 서버나 RPC 계층은 없습니다. 프로세스 종료 코드와 아래 파일 구조가 인터페이스입니다.

## 요구 사항

- macOS 14.2 이상
- Apple Silicon Mac 권장
- Homebrew
- Python 3.12
- ffmpeg
- Xcode Command Line Tools (`swift`, `swiftc`)
- 모델 저장 공간 수 GB
- Hugging Face Read 토큰

Xcode Command Line Tools가 없다면 먼저 설치합니다.

```bash
xcode-select --install
```

Hugging Face 토큰은 <https://huggingface.co/settings/tokens>에서 Read 권한으로 발급할 수 있습니다.

## 빠른 시작

```bash
git clone https://github.com/jingi723/STT.git
cd STT

cp .env.example .env
# .env의 HF_TOKEN 값을 본인 토큰으로 변경

bash build.sh all
open "STT실행.app"
```

`build.sh all`은 다음 작업을 순서대로 수행합니다.

1. Python 3.12, ffmpeg, Swift 도구 및 HF 토큰 확인
2. `STT_env` 가상환경과 Python 의존성 설치
3. `native/apptap` 빌드 및 서명
4. SwiftUI 앱 release 빌드 및 ad-hoc 서명
5. Qwen3-ASR와 pyannote 모델 다운로드

앱이 Gatekeeper에 막히면 Finder에서 `STT실행.app`을 우클릭한 뒤 **열기**를 선택합니다.

## macOS 권한

처음 사용하는 녹음 소스에 따라 macOS가 권한을 요청합니다.

| 기능 | 필요한 권한 |
|---|---|
| Mac·USB·연속성 마이크 | 마이크 |
| 시스템 전체 출력 | 시스템 오디오 녹음 |
| 특정 앱 출력 | 시스템 오디오 녹음 |

권한을 거부했거나 무음이 저장되면 다음 위치에서 `STT실행`, 터미널 또는 실행한 바이너리의 권한을 확인합니다.

```text
시스템 설정
└── 개인정보 보호 및 보안
    ├── 마이크
    └── 화면 및 시스템 오디오 녹음
```

권한 변경 후에는 실행 중인 앱을 완전히 종료하고 다시 실행합니다. 권한을 우회하는 코드는 포함하지 않습니다.

## 앱 사용법

1. `STT실행.app`을 엽니다.
2. 녹음 소스를 선택합니다.
3. 입력 장치 또는 대상 앱을 선택합니다.
4. **녹음 시작**을 누릅니다.
5. 경과 시간, 파일 크기, 입력·출력 레벨을 확인합니다.
6. **녹음 정지**를 눌러 WAV를 finalize합니다.
7. 저장된 세션에서 전사 옵션을 선택하고 **전사 시작**을 누릅니다.
8. 전사가 끝나면 회의록 또는 AI 요약 프롬프트를 생성합니다.

### 녹음 소스

| 소스 | 녹음 대상 | 비고 |
|---|---|---|
| 입력 장치 | Mac 마이크, AirPods, USB 마이크, 연속성 마이크 | macOS 기본 입력 장치를 최초 선택하며 사용자가 선택한 유효 장치는 유지 |
| 시스템 출력 | 이 Mac에서 재생되는 전체 소리 | 마이크 음성은 포함하지 않음 |
| 앱 오디오 | 선택한 프로세스의 출력 | 미팅 앱이나 브라우저 등 특정 앱만 녹음 |

시스템 출력 또는 앱 오디오 모드의 **출력 레벨**은 Mac에서 실제 소리가 재생될 때만 움직입니다.

## 저장 구조

모든 사용자 데이터는 Git에서 제외되는 `outputs/` 아래에 저장됩니다.

```text
outputs/
├── recordings/
│   └── {session-id}/
│       ├── audio.wav
│       └── metadata.json
├── {session-id}.json
├── {session-id}.md
├── {session-id}.partial.json
└── {session-id}.prompt.md
```

- `audio.wav`: 원본 녹음
- `metadata.json`: 소스, 장치, 시간, 상태 및 결과 경로
- `.json`: 화자와 타임스탬프가 포함된 전사 데이터
- `.md`: 사람이 읽는 전사 또는 회의록
- `.partial.json`: 중단된 전사를 이어가기 위한 중간 결과
- `.prompt.md`: 외부 AI 에이전트에 전달할 요약 프롬프트

## CLI

Swift 앱 없이 Python CLI만 사용할 수도 있습니다. 가상환경을 활성화하지 않았다면 저장소의 Python 실행 파일을 직접 사용합니다.

```bash
# 명령 목록
STT_env/bin/python -m meeting_stt --help

# 입력 장치와 캡처 가능한 앱
STT_env/bin/python -m meeting_stt devices
STT_env/bin/python -m meeting_stt apps

# 오디오 → 화자별 전사
STT_env/bin/python -m meeting_stt transcribe meeting.wav \
  --context "프로젝트명, 제품명, 참석자명" \
  --num-speakers 3

# 전사 JSON → 회의록
STT_env/bin/python -m meeting_stt notes outputs/meeting.json \
  --project MyProject

# AI 에이전트용 프롬프트
STT_env/bin/python -m meeting_stt notes outputs/meeting.json \
  --project MyProject \
  --prompt-only

# 전사와 회의록을 한 번에
STT_env/bin/python -m meeting_stt run meeting.wav \
  --context "프로젝트명, 제품명" \
  --num-speakers 3

# LLM-Wiki 구조 생성
STT_env/bin/python -m meeting_stt init-wiki ./LLM-Wiki \
  --project MyProject

# 녹음 파일 정리: 기본은 미리보기
STT_env/bin/python -m meeting_stt clean-audio
STT_env/bin/python -m meeting_stt clean-audio --yes
```

## 로컬 웹 대시보드

기존 FastAPI 대시보드도 유지됩니다.

```bash
STT_env/bin/python -m meeting_stt dashboard
```

브라우저에서 <http://127.0.0.1:8000>을 엽니다. 신규 사용에는 SwiftUI 앱을 권장합니다.

## 빌드 명령

```bash
bash build.sh              # all과 동일
bash build.sh prereqs      # 사전 요구 사항 확인
bash build.sh deps         # Python 가상환경과 의존성
bash build.sh apptap       # Core Audio Process Tap helper
bash build.sh app          # SwiftUI 앱
bash build.sh icon         # 레거시 command 런처 아이콘
bash build.sh models       # Qwen3-ASR와 pyannote 모델
```

## 프로젝트 구조

```text
macos/
└── Sources/MeetingSTTApp/
    ├── MeetingSTTApp.swift
    ├── ContentView.swift
    ├── AppModel.swift
    ├── SessionStore.swift
    ├── ProcessRunner.swift
    └── DeviceRecorder.swift

meeting_stt/
├── audio.py
├── asr.py
├── diarize.py
├── pipeline.py
├── notes.py
├── wiki.py
├── capture.py
├── server.py
└── cli.py

native/
└── apptap.swift
```

| 영역 | 책임 |
|---|---|
| SwiftUI 앱 | UI, Core Audio 입력 녹음, 세션, 재생, worker 수명주기 |
| `native/apptap` | 특정 앱 및 시스템 출력의 Process Tap 녹음 |
| Python 패키지 | ASR, 화자분리, 전사 저장, 회의록과 프롬프트 |
| 디스크 | 세션과 결과의 단일 진실 공급원 |

## 개인정보와 공개 저장소 안전

- `.env`, 모델, 가상환경, 녹음, 전사, 회의록 및 LLM-Wiki는 `.gitignore`에 포함됩니다.
- HF 토큰은 `.env` 또는 `HF_TOKEN` 환경변수에서만 읽습니다.
- 앱은 녹음이나 전사 결과를 별도 서버로 업로드하지 않습니다.
- 공개 저장소에 커밋하기 전 `git status`로 `outputs/`, `.env`, `models/`가 포함되지 않았는지 확인하세요.
- 회의 녹음 전에 참석자의 동의를 받고 지역 법률과 회사 정책을 확인하세요.

## 문제 해결

### 입력 장치가 보이지 않음

macOS의 기본 입력과 권한을 확인한 뒤 앱의 새로고침 버튼을 누릅니다.

```bash
STT_env/bin/python -m meeting_stt devices
```

### 시스템·앱 출력이 무음

시스템 오디오 녹음 권한을 허용하고 앱을 완전히 재시작합니다. 캡처 helper가 정상인지 확인할 수 있습니다.

```bash
bash build.sh apptap
native/apptap list
```

### 출력 레벨이 0%

시스템 출력 모드에서는 Mac에서 음악, 영상 또는 통화 상대방 음성이 실제로 재생되어야 합니다. 마이크에 말하는 소리는 시스템 출력 레벨에 포함되지 않습니다.

### 프로젝트 루트를 찾지 못함

`STT실행.app`을 저장소 루트에 두거나 환경변수로 루트를 지정합니다.

```bash
MEETING_STT_ROOT="$PWD" "./STT실행.app/Contents/MacOS/MeetingSTTApp"
```

### 모델 또는 Python 경로 오류

```bash
bash build.sh deps
bash build.sh models
```

## 개발 검증

```bash
# Swift 앱
swift build --package-path macos -c release

# native helper
bash build.sh apptap
native/apptap list

# Python 문법·import·CLI
STT_env/bin/python -m py_compile meeting_stt/*.py
STT_env/bin/python -c "import meeting_stt; print('import OK')"
STT_env/bin/python -m meeting_stt --help
```

## 라이선스

이 저장소에는 아직 별도의 오픈소스 라이선스가 지정되지 않았습니다. 공개 열람은 가능하지만 복제, 수정 및 재배포 권한은 자동으로 부여되지 않습니다. Qwen3-ASR, pyannote 및 기타 의존성에는 각각의 라이선스가 적용됩니다.
