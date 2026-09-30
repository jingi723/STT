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

# {{date}} {{project}} Meeting notes

## 1. Meeting overview

## 2. Key discussion

## 3. Decisions
| Decision | Evidence | Related documents |
|------|------|-----------|

## 4. Action items
| Owner | Task | Deadline | Supporting statement | Status |
|--------|------|--------|-----------|------|

## 5. Risks / Needs confirmation

## 6. Next meeting agenda

## 7. Source transcript link
"""

ACTION_ITEM_TEMPLATE = """- [ ] **{Owner}** — {Task} (Due: {Deadline})
  - Supporting statement: "{Quote}"
  - Status: Not started | In progress | Complete
"""


def _seed_files(project: str) -> Dict[str, str]:
    """프로젝트별 LLM-Wiki 시드 파일 (상대경로 -> 내용)."""
    proj = f"02_Projects/{project}"
    return {
        "04_Templates/meeting-template.md": MEETING_TEMPLATE,
        "04_Templates/action-item-template.md": ACTION_ITEM_TEMPLATE,
        f"{proj}/project-overview.md": f"# {project} Project overview\n\n- Goals:\n- Scope:\n- Current status:\n",
        f"{proj}/glossary.md": "# Glossary\n\n| Term | Description |\n|------|------|\n",
        f"{proj}/decisions.md": "# Decision log\n\n| Date | Decision | Evidence |\n|------|------|------|\n",
        f"{proj}/meeting-log.md": "# Meeting log\n\n| Date | Meeting | Link |\n|------|------|------|\n",
        "03_People/team-members.md": "# Team members\n\n| Name | Role | Speaker label |\n|------|------|----------|\n",
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
