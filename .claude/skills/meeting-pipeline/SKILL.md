---
name: meeting-pipeline
description: 화자 귀속 전사를 만들고 LLM-Wiki 회의록을 생성하는 파이프라인·CLI를 구현/수정할 때 사용. pipeline.py/notes.py/wiki.py/cli.py, LLM-Wiki 폴더 구조, 회의록 템플릿·요약 프롬프트 작업 시 반드시 이 스킬을 따른다.
---

# Meeting Pipeline 구현 스킬

ASR·화자분리 결과를 합쳐 회의록까지 만드는 통합 계층(`pipeline.py`, `notes.py`, `wiki.py`, `cli.py`) 구현 방법. 강의자료(AI회의록_강의자료.pptx)의 LLM-Wiki 설계를 따른다.

## 데이터 흐름
```
오디오 → [audio.chunk] → [diarize.run → 세그먼트] → 세그먼트별 [asr.transcribe]
      → 화자 귀속 transcript → [notes 생성 (LLM-Wiki 참조)] → 회의록 markdown
```

## pipeline.py
- `audio`/`asr`/`diarize` 모듈을 조합한다(직접 모델 코드 작성 금지 — 그 책임은 asr-diarization 스킬).
- 화자 귀속 transcript 형식: `[SPEAKER_00] 00.0s~14.0s: 텍스트` 라인들.
- 산출물(회의 1건 = 텍스트 2개 + 음성 1개, 무거운 음성과 분리):
  - `outputs/{stem}.md`(사람용 — 전사, notes 실행 시 회의록으로 통합) + `outputs/{stem}.json`(세그먼트 데이터).
  - 음성은 `outputs/recordings/{stem}.wav`에 따로 둬 `clean-audio`로 쉽게 삭제(공간 확보). 별도 `_transcript`/`_notes` 분리 파일은 만들지 않는다(회의당 한 .md).
- json 세그먼트 스키마: `{"speaker","start","end","text"}` 배열 + 메타(`audio_path","model","context"`).

## wiki.py — LLM-Wiki
강의자료 슬라이드의 폴더 구조를 스캐폴딩하고 참조 파일을 읽는다.
```
LLM-Wiki/
  00_Inbox/
  01_Meetings/
  02_Projects/{project}/  project-overview.md · glossary.md · decisions.md · meeting-log.md
  03_People/              team-members.md
  04_Templates/           meeting-template.md · action-item-template.md
  05_Archive/
```
- `init_wiki(path)` — 위 구조와 템플릿 파일 생성(이미 있으면 보존).
- `read_context(wiki_path, project)` — project-overview/glossary/decisions/team-members를 읽어 dict로 반환(없으면 빈 값).

## notes.py — 회의록 생성 (두 경로)
1. **템플릿 기반 로컬 생성(기본)** — transcript에서 강의자료 템플릿 골격을 채운 markdown 생성. 자동 추출이 불확실한 항목은 `[확인 필요]`로 표시. 없는 내용을 지어내지 않는다.
2. **AI Agent 프롬프트 출력** — `outputs/{stem}.prompt.md`에 강의자료의 LLM-Wiki 참조 프롬프트 + transcript를 함께 출력(요청 시에만). 사용자가 Claude Code/Codex로 이 파일을 열어 고품질 회의록을 생성한다.

회의록 본문 섹션(강의자료 meeting-template.md 기준):
1. 회의 개요 2. 핵심 논의 3. 결정사항(결정·근거·관련문서) 4. 액션아이템(담당자·작업·마감일·근거발화·상태) 5. 리스크/확인 필요 6. 다음 회의 아젠다. frontmatter에 type/date/project/source_audio/stt_model/diarization_model/participants/tags.

요약 프롬프트·템플릿 전문은 `references/templates.md` 참조.

## cli.py — 서브커맨드
- `transcribe AUDIO [--context "키워드,..."] [--num-speakers N] [--no-diarize]` → transcript 산출.
- `notes TRANSCRIPT_JSON [--wiki LLM-Wiki] [--project NAME] [--prompt-only]` → 회의록 또는 요약 프롬프트.
- `run AUDIO [...]` → transcribe + notes 전체.
- `init-wiki PATH [--project NAME]` → LLM-Wiki 스캐폴딩.
- `python -m meeting_stt --help`가 반드시 동작해야 한다(QA 검증 항목).

## 원칙
- 없는 내용 생성 금지, 불확실은 `[확인 필요]`. (강의자료 프롬프트 규칙)
- SPEAKER_00 등은 익명 라벨 — team-members.md로 실명 매핑을 제안하되 강제하지 않는다.
