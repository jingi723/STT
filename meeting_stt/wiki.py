"""LLM-Wiki 폴더 구조 스캐폴딩 및 참조 파일 읽기. 외부 의존성 없음(import-safe)."""

from __future__ import annotations

from pathlib import Path
from typing import Dict

MEETING_TEMPLATE = """---
type: meeting
date: {{date}}
project: {{project}}
source_audio: {{source_audio}}
stt_model: Qwen3-ASR-1.7B
diarization_model: pyannote/speaker-diarization-3.1
participants: []
tags: [meeting, stt, llm-wiki]
---

# {{date}} {{project}} 회의록

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
"""

ACTION_ITEM_TEMPLATE = """- [ ] **{담당자}** — {작업} (마감: {마감일})
  - 근거 발화: "{인용}"
  - 상태: 진행 전 | 진행 중 | 완료
"""


def _seed_files(project: str) -> Dict[str, str]:
    """프로젝트별 LLM-Wiki 시드 파일 (상대경로 -> 내용)."""
    proj = f"02_Projects/{project}"
    return {
        "04_Templates/meeting-template.md": MEETING_TEMPLATE,
        "04_Templates/action-item-template.md": ACTION_ITEM_TEMPLATE,
        f"{proj}/project-overview.md": f"# {project} 프로젝트 개요\n\n- 목표:\n- 범위:\n- 현재 상태:\n",
        f"{proj}/glossary.md": "# 용어집\n\n| 용어 | 설명 |\n|------|------|\n",
        f"{proj}/decisions.md": "# 결정 로그\n\n| 날짜 | 결정 | 근거 |\n|------|------|------|\n",
        f"{proj}/meeting-log.md": "# 회의 로그\n\n| 날짜 | 회의 | 링크 |\n|------|------|------|\n",
        "03_People/team-members.md": "# 팀원\n\n| 이름 | 역할 | 화자라벨 |\n|------|------|----------|\n",
    }


DIRS = [
    "00_Inbox",
    "01_Meetings",
    "02_Projects",
    "03_People",
    "04_Templates",
    "05_Archive",
]


def init_wiki(wiki_path: str, project: str = "My-app") -> Path:
    """강의자료의 LLM-Wiki 폴더 구조와 시드 파일을 생성한다. 기존 파일은 보존."""
    root = Path(wiki_path)
    for d in DIRS:
        (root / d).mkdir(parents=True, exist_ok=True)
    (root / f"02_Projects/{project}").mkdir(parents=True, exist_ok=True)
    for rel, content in _seed_files(project).items():
        f = root / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        if not f.exists():  # 기존 내용 보존
            f.write_text(content, encoding="utf-8")
    return root


def read_context(wiki_path: str, project: str = "My-app") -> Dict[str, str]:
    """notes 생성에 쓸 참조 파일들을 읽어 dict로 반환. 없으면 빈 문자열."""
    root = Path(wiki_path)
    proj = f"02_Projects/{project}"
    targets = {
        "project_overview": f"{proj}/project-overview.md",
        "glossary": f"{proj}/glossary.md",
        "decisions": f"{proj}/decisions.md",
        "team_members": "03_People/team-members.md",
    }
    ctx: Dict[str, str] = {}
    for key, rel in targets.items():
        f = root / rel
        ctx[key] = f.read_text(encoding="utf-8") if f.exists() else ""
    return ctx
