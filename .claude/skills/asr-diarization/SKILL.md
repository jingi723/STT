---
name: asr-diarization
description: Qwen3-ASR-1.7B 음성인식과 pyannote 화자분리 모듈을 구현/수정할 때 사용. 오디오 로딩·청킹, context biasing(쉼표 키워드 주입), 화자분리 세그먼트 추출, 화자별 전사 코드를 다룰 때 반드시 이 스킬을 따른다. audio.py/asr.py/diarize.py 작업 시 적용.
---

# ASR & Diarization 구현 스킬

`meeting_stt`의 음성 처리 계층(`audio.py`, `asr.py`, `diarize.py`)을 구현하는 방법. `test.ipynb`에서 동작이 검증된 로직을 기반으로 하되, 발견된 버그를 고치고 Qwen3 단일 모델로 정리한다.

## 모델 정책
- **ASR: Qwen3-ASR-1.7B 하나만.** Whisper는 쓰지 않는다. 이유: 강의 핵심인 context biasing(고유명사·참석자 이름 주입)을 지원하고 회의 도메인에 적합. 모델 두 개를 받지 않아 디스크/다운로드 비용도 절감.
- **화자분리: pyannote** speaker-diarization-3.1 + segmentation-3.0.

## 반드시 고칠 버그 (노트북에서 발견)
1. **soundfile import 누락** — `sf.write(...)`를 쓰는 모듈은 상단에 `import soundfile as sf`가 반드시 있어야 한다. 노트북은 화자분리 셀에서야 import해 앞 셀 단독 실행 시 `NameError`가 났다.
2. **context prompt 형식** — 강의자료 명시: 실제 주입은 **쉼표로 구분된 키워드**만. 문장형("이 회의는 …입니다")이 아니라 `"LLM-Wiki, Obsidian, Qwen3-ASR, 김상규, ..."` 형태. distractor(무관한 단어)를 섞지 않는다 — 정확도를 오히려 떨어뜨린다.
3. **Whisper 잔재 제거** — `transformers.pipeline`, `whisper_pipe` 등 일절 작성하지 않는다.
4. **중복 로드 제거** — 오디오는 한 번만 로드해 재사용한다.

## 핵심 파라미터 (검증된 값 — 임의 변경 금지)
- 청킹: `CHUNK_SEC=30`, `OVERLAP_SEC=2`, `STEP_SEC=28`.
- 화자분리: `pipeline.segmentation.min_duration_off = 1.0` (1초 이하 묵음은 같은 발화로 묶음).
- 디바이스/dtype: CUDA면 `cuda:0`+`bfloat16`, 아니면 `cpu`+`float32`.
- Qwen3 로딩: `max_inference_batch_size=8`, `max_new_tokens=512`.

## 구현 패턴
검증된 코드 스니펫(오디오 로딩/청킹, Qwen3 전사, pyannote 화자분리, 화자별 전사)은 `references/proven-code.md`에 정리되어 있다. 모듈 작성 시 이 파일을 읽고 함수/클래스로 감싼다.

## 지연 로딩 원칙
모델 로딩은 클래스 `__init__` 또는 명시적 `load()`에서만 수행한다. 모듈을 `import`하는 것만으로 torch가 모델을 받거나 GPU를 점유하면 안 된다(테스트·CLI `--help`가 무거워짐).

## 에러 메시지
- 모델 폴더 없음 → "models/Qwen3-ASR 가 없습니다. setup.ipynb Step 7을 실행하세요." 처럼 다음 행동을 알려준다.
- HF 토큰 없음(`.env`의 HF_TOKEN/환경변수) → 발급·설정 경로를 안내한다.
