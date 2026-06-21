---
name: run-verify-stt
description: 구현된 meeting_stt 프로그램이 실제로 동작하는지 실행·검증할 때 사용. 컴파일·import·CLI·경계면 정합성 점검, 환경(venv·모델) 준비 확인, 실제 전사 실행 검증 시 반드시 이 스킬을 따른다.
---

# Run & Verify STT 스킬

`meeting_stt`가 실제로 동작하는지 검증하는 방법. **환경 비의존 검증(항상 가능)** 과 **환경 의존 검증(venv·모델 필요)** 을 구분한다.

## A. 환경 비의존 검증 (항상 수행)
torch/모델이 없어도 통과해야 하는 항목. CI·QA의 1차 게이트.

```bash
# 1) 전 모듈 문법 컴파일
python -m py_compile meeting_stt/*.py

# 2) import 안전성 (지연 로딩 — 모델 없이 import 성공해야 함)
python -c "import meeting_stt; print('import OK')"

# 3) CLI 진입점
python -m meeting_stt --help
python -m meeting_stt transcribe --help
python -m meeting_stt notes --help
python -m meeting_stt run --help
python -m meeting_stt init-wiki --help

# 4) LLM-Wiki 스캐폴딩 (외부 의존 없음)
python -m meeting_stt init-wiki ./LLM-Wiki --project My-app
```

import이 무거운 의존성(torch, qwen_asr, pyannote)을 모듈 최상단에서 끌어오면 2)가 실패한다 → 지연 로딩으로 고친다.

## B. 경계면 정합성 검증
한 모듈 출력 shape이 다음 모듈 입력과 맞는지 코드를 교차로 읽어 확인한다.
- `chunk_audio` 반환 dict 키 ↔ `asr` 사용 키
- `Diarizer.run` 세그먼트 dict 키(`speaker/start/end`) ↔ `pipeline` 화자 귀속 로직
- `pipeline` json 스키마 ↔ `notes`가 읽는 키
- `wiki.read_context` 반환 키 ↔ `notes` 프롬프트 치환 키

## C. 환경 의존 검증 (가능할 때만)
venv·모델이 준비된 경우에만. 없으면 "환경 미준비로 건너뜀"을 명시(조용히 통과 처리 금지).

```bash
# 짧은 샘플 오디오로 전체 파이프라인 (CPU면 5분 이내 오디오 권장 — 강의자료)
python -m meeting_stt run sample.mp3 --context "LLM-Wiki, Qwen3-ASR, 화자분리" --num-speakers 2
# 산출물 확인: outputs/sample_transcript.md, outputs/sample_transcript.json
```

준비 상태 점검:
```bash
test -d models/Qwen3-ASR && echo "Qwen3 OK" || echo "Qwen3 미설치 (setup.ipynb Step 7)"
test -d models/pyannote-diarization && echo "pyannote OK" || echo "pyannote 미설치"
test -f .env && grep -q HF_TOKEN .env && echo "HF_TOKEN OK" || echo "HF 토큰 없음 (.env 또는 환경변수 HF_TOKEN)"
ffmpeg -version >/dev/null 2>&1 && echo "ffmpeg OK" || echo "ffmpeg 없음"
```

## 보고 원칙
- 통과/실패를 단정적으로. 실패는 파일·라인·원인·재현 명령을 적는다.
- 환경 미준비로 건너뛴 항목은 "건너뜀"으로 분명히 표기한다. 미실행을 통과로 보고하지 않는다.
