---
name: web-dashboard
description: 로컬 웹 대시보드(FastAPI 백엔드 + 브라우저 UI)를 구현/수정할 때 사용. server.py 라우트, web/index.html 프론트, 장치 선택·녹음 제어·전사·회의록 보기, dashboard CLI 서브커맨드 작업 시 반드시 이 스킬을 따른다.
---

# Web Dashboard 구현 스킬

`meeting_stt/server.py` + `meeting_stt/web/index.html` — localhost에서 뜨는 대시보드. 녹음·장치선택·전사·회의록 보기를 한 화면에서.

## 구성
- 백엔드 FastAPI가 녹음(`capture`)·전사(`pipeline`)·회의록(`notes`)을 수행.
- 프론트는 단일 HTML + 바닐라 JS(fetch). 빌드 스텝 없음. 브라우저는 화면 표시·버튼만 담당, 녹음은 백엔드가 한다.

## import-safe 원칙 (중요)
fastapi/uvicorn은 모듈 최상단이 아니라 `create_app()`·`run_server()` **내부에서 지연 import**한다. 이유: `python -m py_compile`과 `import meeting_stt.server`가 fastapi 미설치 환경에서도 통과해야 하고(QA 게이트), CLI `--help`가 가벼워야 한다.

## 함정: future annotations + 지역 Pydantic 모델 (실측 버그)
`server.py`에 **`from __future__ import annotations`를 쓰지 말 것.** create_app() 안에 정의한 지역 Pydantic 모델(StartBody 등)을 FastAPI가 본문 모델로 인식하려면 애노테이션이 **실제 클래스 객체**여야 한다. future import가 켜지면 애노테이션이 문자열("StartBody")이 되고, FastAPI가 모듈 전역에서 그 이름을 못 찾아 본문이 아니라 **쿼리 스칼라**로 취급 → POST 본문이 무시되고 `422 Field required (query, body)`가 난다(=대시보드 "녹음 시작 실패"). 모델을 지역에 두면서 import-safe(pydantic 지역 import)도 지키려면 future import 제거가 정답.
**검증:** POST 라우트는 GET만 보지 말고 반드시 **본문을 실제로 보내** 200을 확인한다(`curl -d '{...}'`).

## 라우트 (고정)
| 메서드 | 경로 | 동작 |
|--------|------|------|
| GET | `/` | `web/index.html` 서빙 |
| GET | `/api/devices` | `capture.list_input_devices()` |
| POST | `/api/record/start` | body `{device}` → 녹음 시작 |
| POST | `/api/record/stop` | 정지·wav 저장 → `{path}` |
| POST | `/api/transcribe` | body `{path, context, num_speakers, diarize}` → `pipeline.transcribe` 결과 |
| POST | `/api/notes` | body `{transcript_json, project, prompt_only}` → `notes` 산출 |
| GET | `/api/results` | `outputs/` 산출물 목록 |

## 상태 관리
- 녹음 상태는 서버 프로세스가 단일 `Recorder` 인스턴스로 보유.
- start 중복 호출 → 409, stop인데 미시작 → 400. 명확한 JSON 에러.
- 전사는 동기로 오래 걸릴 수 있음(CPU). 프론트는 "처리 중" 표시 후 응답 대기. (스트리밍은 후속 확장.)

## 프론트(web/index.html) 요소
- 장치 드롭다운(새로고침 버튼) — 시스템 오디오 안내 문구(BlackHole) 포함.
- context 키워드 입력(쉼표 구분 — asr-diarization 규칙 그대로), 화자 수 입력, 화자분리 토글.
- 녹음/정지 버튼 + 경과 시간, 상태 배지.
- 전사 결과(화자 귀속 텍스트) 패널, 회의록 생성 버튼(로컬/프롬프트), 결과 markdown 표시.
- 에러는 화면에 노출(조용히 삼키지 않음).

## CLI 연동
- `python -m meeting_stt dashboard [--host 127.0.0.1] [--port 8000]` → `run_server()`가 uvicorn으로 `create_app()` 구동.
- `dashboard --help`는 fastapi 미설치여도 동작해야 한다(지연 import 덕분).

## 재사용
- 전사·회의록은 기존 `pipeline`/`notes`를 그대로 호출(중복 구현 금지).
- wav 저장·context 정규화 등은 기존 모듈 함수 재사용.
