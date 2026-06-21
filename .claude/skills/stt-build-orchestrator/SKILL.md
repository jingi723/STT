---
name: stt-build-orchestrator
description: STT 회의록 자동화 프로그램(meeting_stt)을 구현·수정·재실행할 때 사용하는 오케스트레이터. "STT 프로그램 만들어/구현해", "회의록 파이프라인 구현", "ASR/화자분리/회의록 코드 작성·수정", "다시 실행/재실행/업데이트/보완", "전사·요약 기능 추가" 등의 요청 시 반드시 이 스킬로 에이전트 팀을 구성해 처리한다. 단순 개념 질문은 직접 응답 가능.
---

# STT Build Orchestrator

`meeting_stt`(로컬 ASR·화자분리·LLM-Wiki 회의록 파이프라인)를 구현/유지보수하는 에이전트 팀을 조율한다.

**실행 모드:** 에이전트 팀 (파이프라인 + 생성-검증). 모든 Agent 호출에 `model: "opus"`.

## 범위 고정
- ASR: **Qwen3-ASR-1.7B 단일**(Whisper 제외). 화자분리: pyannote.
- 산출물: `meeting_stt/` 패키지 + CLI + 로컬 웹 대시보드 + `LLM-Wiki/` 스캐폴딩.
- 대시보드: 로컬 웹(FastAPI + 브라우저 UI). 녹음은 백엔드가 수행. 두 소스: (1) 마이크/입력 장치(`sounddevice`), (2) 앱별 오디오(네이티브 `native/apptap`, Core Audio Process Tap, macOS 14.2+). 전사 타이밍은 녹음 후 전사(준실시간은 후속 확장).
- 앱별 캡처는 TCC 오디오 권한 필요 — 코드 우회 금지, 권한 안내로 처리(native-audio-capture 스킬).

## Phase 0: 컨텍스트 확인
1. `_workspace/` 존재 여부로 실행 모드 판별:
   - 없음 → **초기 구현**: 전체 Phase 실행.
   - 있음 + 부분 수정 요청 → **부분 재실행**: 해당 에이전트만 재호출.
   - 있음 + 새 입력 → **새 실행**: 기존 `_workspace/`를 `_workspace_prev/`로 이동 후 재시작.
2. 기존 `meeting_stt/` 코드가 있으면 에이전트는 읽고 개선하는 방식으로 동작.

## Phase 1: 설계
- `stt-architect`(opus) 호출 → `_workspace/01_architect_design.md` 생성.
- 모듈 계약·데이터 구조·CLI 명세·버그 수정 목록 확정.

## Phase 2: 구현 (팀, 병렬)
설계 확정 후 팀을 구성한다. 작업 범위에 따라 필요한 엔지니어만 호출한다.
- `asr-engineer`(opus, general-purpose) → `audio.py`/`asr.py`/`diarize.py`. **asr-diarization 스킬** 적용.
- `pipeline-engineer`(opus, general-purpose) → `pipeline.py`/`wiki.py`/`notes.py`/`cli.py`. **meeting-pipeline 스킬** 적용.
- `audio-capture-engineer`(opus, general-purpose) → `capture.py`. **audio-capture 스킬** 적용. (대시보드/녹음 작업 시)
- `dashboard-engineer`(opus, general-purpose) → `server.py`/`web/index.html` + CLI `dashboard`. **web-dashboard 스킬** 적용. (대시보드 작업 시)
- 엔지니어들은 SendMessage로 모듈 시그니처를 조율한다(경계면 불일치 방지). 대시보드는 `capture`·`pipeline`·`notes`를 재사용하므로 중복 구현 금지.

## Phase 3: 검증 (점진적)
- `qa-verifier`(opus, general-purpose) → **run-verify-stt 스킬** 적용. 각 모듈 완성 직후 점진 검증.
- 환경 비의존 검증(컴파일·import·CLI·경계면)은 필수. 환경 의존(실제 추론)은 가능할 때만, 불가 시 "건너뜀" 명시.
- 버그 발견 → 담당 엔지니어에게 SendMessage로 파일·라인 전달 후 재검증. 1회 재시도 후 미해결이면 `_workspace/04_qa_report.md`에 남기고 진행.

## 데이터 전달 프로토콜
- 태스크 기반(TaskCreate, 의존성 관리) + 파일 기반(`_workspace/` 중간 산출물 + `meeting_stt/` 최종 코드) + 메시지 기반(SendMessage 실시간 조율).
- 파일명: `{phase}_{agent}_{artifact}.md` (예: `02_asr_engineer.md`).

## 에러 핸들링
- 모델/torch 미설치는 정상 상황으로 간주 — 코드는 import·CLI가 동작하도록 작성하고, 실제 추론 검증만 건너뛴다.
- 상충하는 설계 의견은 삭제하지 않고 출처 병기 후 architect가 판정.

## 완료 기준
- `python -m py_compile meeting_stt/*.py` 통과.
- `python -m meeting_stt --help` 및 서브커맨드 `--help` 동작.
- `python -m meeting_stt init-wiki ./LLM-Wiki` 가 LLM-Wiki 구조 생성.
- `_workspace/04_qa_report.md`에 항목별 통과/건너뜀 기록.
- 사용자에게 결과 요약 + 실제 추론 실행에 필요한 다음 단계(venv·모델·`.env`의 HF_TOKEN) 안내.

## 테스트 시나리오
- **정상 흐름:** "STT 회의록 프로그램 구현해줘" → Phase1~3 → 패키지 생성 → QA 통과 → 사용법 안내.
- **에러 흐름:** QA에서 경계면 불일치(예: pipeline이 기대하는 json 키와 notes가 읽는 키 불일치) 발견 → 담당 엔지니어 재호출 → 수정 → 재검증 → 통과.

## 진화
- 실행 후 사용자 피드백을 받아 해당 스킬/에이전트/이 오케스트레이터를 갱신하고 CLAUDE.md 변경 이력에 기록한다.
