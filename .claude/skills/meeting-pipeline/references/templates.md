# 회의록 템플릿 & 요약 프롬프트 (강의자료 기반)

## meeting-template.md (04_Templates/)

```markdown
---
type: meeting
date: {date}
project: {project}
source_audio: {source_audio}
stt_model: Qwen3-ASR-1.7B
diarization_model: pyannote/speaker-diarization-3.1
participants: []
tags: [meeting, stt, llm-wiki]
---

# {date} {project} 회의록

## 1. 회의 개요

## 2. 핵심 논의

## 3. 결정사항
| 결정 | 근거 | 관련 문서 |
|------|------|-----------|

## 4. 액션아이템
| 담당자 | 작업 | 마감일 | 근거 발화 | 상태 |
|--------|------|--------|-----------|------|

## 5. 리스크 / 확인 필요

## 6. 다음 회의 아젠다

## 7. 원본 transcript 링크
```

## action-item-template.md (04_Templates/)

```markdown
- [ ] **{담당자}** — {작업} (마감: {마감일})
  - 근거 발화: "{인용}"
  - 상태: 진행 전 | 진행 중 | 완료
```

## LLM-Wiki 참조 요약 프롬프트 (notes.py --prompt-only 출력용)

강의자료 슬라이드 26·27 기반. transcript와 함께 이 프롬프트를 출력해 사용자가 Claude Code/Codex로 회의록을 생성하게 한다.

```text
당신은 회의록 작성 보조자입니다. 다음 LLM-Wiki 파일을 먼저 참고하세요.
- 02_Projects/{project}/project-overview.md
- 02_Projects/{project}/glossary.md
- 02_Projects/{project}/decisions.md
- 03_People/team-members.md

그 다음 아래 transcript를 읽고 회의록을 작성하세요.

요구사항:
- 없는 내용을 만들어내지 말 것. 불확실한 내용은 [확인 필요]로 표시.
- 결정사항과 액션아이템을 분리. 액션아이템에는 담당자·작업·마감일·근거 발화 포함.
- 기존 결정과 충돌하면 [기존 결정과 충돌 가능]으로 표시.
- 새로 등장한 용어는 glossary 업데이트 후보로 따로 정리.
- SPEAKER_00 등 익명 라벨은 team-members.md로 실명 매핑을 시도하되, 불확실하면 라벨 유지.
- 출력은 04_Templates/meeting-template.md 형식의 Markdown.

--- TRANSCRIPT ---
{transcript}
```

## 초기 LLM-Wiki 시드 파일 (init-wiki가 생성)

- `02_Projects/{project}/project-overview.md` — 프로젝트 목표/범위 placeholder.
- `02_Projects/{project}/glossary.md` — 용어집 표 헤더 `| 용어 | 설명 |`.
- `02_Projects/{project}/decisions.md` — 결정 로그 표 헤더 `| 날짜 | 결정 | 근거 |`.
- `03_People/team-members.md` — `| 이름 | 역할 | 화자라벨 |`.
