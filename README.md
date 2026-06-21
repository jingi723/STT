# meeting_stt — 로컬 STT 회의록 자동화

`notebooks/test.ipynb` 실습 코드를 실제 동작하는 Python 패키지+CLI로 구현한 회의록 파이프라인.
**Qwen3-ASR-1.7B**(음성인식, context biasing) + **pyannote**(화자분리) + **LLM-Wiki**(회의록).

## 파이프라인
```
오디오 → 화자분리(pyannote) → 세그먼트별 전사(Qwen3-ASR) → 화자 귀속 transcript → 회의록(LLM-Wiki)
```

## Quick Start (처음 받는 사람 · macOS)
```bash
git clone <이 저장소> && cd STT
cp .env.example .env          # .env 열어 HF_TOKEN=hf_본인토큰 입력 (무료)
bash build.sh                 # 준비물 점검·venv·의존성·apptap·모델(~4GB)·아이콘
# → Finder에서 STT실행.command 더블클릭 (첫 실행: 우클릭→열기→열기)
```
- **macOS 전용**입니다(앱 오디오 캡처·런처가 맥 기반). Python 3.12·ffmpeg·Xcode CLT가 없으면 `build.sh`가 안내/설치합니다(Homebrew 필요).
- HF 토큰: https://huggingface.co/settings/tokens 에서 **Read** 토큰 발급.

## 디렉터리 구조
```
meeting_stt/   프로그램 패키지 (asr·diarize·pipeline·notes·wiki·capture·server·cli·web)
native/        앱별 오디오 캡처 헬퍼 (Swift) — apptap.swift
scripts/       download_models.py (모델 다운로드)
notebooks/     setup.ipynb, test.ipynb (강의/참고)
assets/        아이콘 원본(stt-icon.png/icns)
build.sh       빌드/셋업 통합 스크립트
STT실행.command                  원클릭 런처(아이콘 포함, macOS)
.env           HF_TOKEN=hf_...   (미커밋)
models/ STT_env/                 런타임(미커밋)
.claude/       에이전트·스킬 하네스
```

## 설치 (한 방)
```bash
bash build.sh        # venv·의존성·ffmpeg확인·apptap빌드·모델다운로드·아이콘적용
```
부분 실행: `bash build.sh deps|apptap|icon|models`

준비물:
- Python 3.12, ffmpeg (`brew install ffmpeg`)
- **HF 토큰**: 프로젝트 루트에 `.env` 파일 → `HF_TOKEN=hf_...` (또는 환경변수 `export HF_TOKEN=...`)
- 화자분리는 비-gated 미러(`pyannote-community/speaker-diarization-community-1`)라 약관 동의 불필요

> `notebooks/setup.ipynb`는 강의용(Windows) 참고. macOS는 `build.sh`로 충분.

## 대시보드 (로컬 웹)

### 원클릭 실행 (권장)
- **`STT실행.command` 더블클릭** (첫 실행 시 보안 경고 → 우클릭 → 열기 → 열기)
- 아이콘이 안 보이면(git/압축 후 사라질 수 있음): `bash build.sh icon`

가상환경(`STT_env`)을 자동으로 찾아 대시보드를 켜고 브라우저(`http://127.0.0.1:8000`)를 엽니다. 환경/의존성이 없으면 설치 안내를 보여줍니다.

### 명령어로 실행
브라우저에서 장치 선택·녹음·전사·회의록을 한 화면에서.
```bash
python -m meeting_stt dashboard            # http://127.0.0.1:8000
python -m meeting_stt devices              # 입력 장치 목록만 확인
```
- 녹음은 **백엔드** 가 수행. 두 가지 소스:
  - **🎙️ 마이크/입력 장치** — `sounddevice`로 마이크·라인입력 선택.
  - **🖥️ 앱 오디오** — 특정 앱(Zoom/Meet 등)의 소리만 캡처. 라우팅 불필요, 들으면서 녹음. (macOS 14.2+, 네이티브 헬퍼 `native/apptap`)

### 앱별 오디오 캡처 (웹미팅 소리 녹음)
웹미팅 상대방 목소리는 "앱 오디오" 소스로 녹음합니다.
```bash
bash build.sh apptap          # apptap 헬퍼 빌드(최초 1회, swiftc 필요)
python -m meeting_stt apps     # 캡처 가능한 앱 목록
```
대시보드에서 소스 종류 = "앱 오디오" → 미팅 앱 선택 → 녹음.

> ⚠️ **권한(최초 1회):** macOS가 오디오 캡처 권한을 요구합니다. 처음 녹음 시 프롬프트가 뜨면 허용하거나, **시스템 설정 → 개인정보 보호 및 보안 → 오디오 녹음**(또는 화면/시스템 오디오 기록)에서 **터미널(또는 실행한 앱)** 을 허용한 뒤 다시 녹음하세요. 권한이 없으면 녹음은 되지만 **무음**으로 저장됩니다.

> 대안(BlackHole): `brew install blackhole-2ch` 후 다중 출력 장치를 만들어 입력 장치로 선택해도 시스템 오디오를 녹음할 수 있습니다.

## 사용법 (CLI)
```bash
# LLM-Wiki 폴더 구조 생성
python -m meeting_stt init-wiki ./LLM-Wiki --project My-app

# 오디오 → 화자 귀속 transcript (context biasing은 쉼표 키워드)
python -m meeting_stt transcribe 회의.mp3 --context "LLM-Wiki, Qwen3-ASR, 화자분리, 김상규" --num-speakers 3

# transcript → 회의록(로컬 템플릿)  또는  AI Agent 요약 프롬프트(--prompt-only)
python -m meeting_stt notes outputs/회의.json --wiki ./LLM-Wiki --project My-app
python -m meeting_stt notes outputs/회의.json --prompt-only   # Claude Code/Codex로 요약

# 전체 한 번에
python -m meeting_stt run 회의.mp3 --context "..." --num-speakers 3 --wiki ./LLM-Wiki

# 녹음 음성(.wav) 일괄 삭제로 공간 확보 (텍스트는 보존)
python -m meeting_stt clean-audio          # 미리보기(용량 확인)
python -m meeting_stt clean-audio --yes    # 실제 삭제
```

## 산출물 (회의 1건 = 텍스트 2개 + 음성 1개)
무거운 음성과 가벼운 텍스트를 분리 — 음성만 지워 공간을 비울 수 있다.
```
outputs/
├── {이름}.md        ← 전사 + 회의록 (한 파일, 사람용). notes 실행 시 이 파일에 통합
├── {이름}.json      ← 재생성용 데이터(작음). 음성 지워도 회의록 재생성 가능
├── {이름}.prompt.md ← (--prompt-only 시) AI Agent용 요약 프롬프트
└── recordings/{이름}.wav   ← 원본 음성(용량 큼). `clean-audio`로 삭제 가능
```

## 패키지 구조
| 모듈 | 역할 |
|------|------|
| `config.py` | 경로·디바이스(지연 import)·HF 토큰(.env/env) |
| `audio.py` | 로딩·30s/2s 청킹·wav 쓰기(soundfile import 보장) |
| `asr.py` | Qwen3-ASR 래퍼, context biasing |
| `diarize.py` | pyannote 화자분리(`min_duration_off=1.0`) |
| `pipeline.py` | 통합 전사·저장 |
| `wiki.py` | LLM-Wiki 스캐폴딩·참조 읽기 |
| `notes.py` | 회의록/요약 프롬프트 생성 |
| `capture.py` | 오프라인 녹음·입력장치 열거(sounddevice) |
| `server.py` + `web/` | 로컬 웹 대시보드(FastAPI + 바닐라 JS) |
| `cli.py` | `transcribe`/`notes`/`run`/`init-wiki`/`dashboard`/`devices` |

> 무거운 의존성(torch/qwen_asr/pyannote)은 함수 내부에서 지연 import — `import meeting_stt`만으로 모델을 받지 않는다.

## 하네스
이 프로젝트는 `.claude/`에 에이전트 팀 하네스를 갖는다. STT 코드 구현·수정·재실행 요청 시 `stt-build-orchestrator` 스킬이 트리거된다(자세한 내용은 `CLAUDE.md`).
