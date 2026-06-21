"""회의록 생성. 두 경로: (1) 템플릿 기반 로컬 생성, (2) AI Agent용 요약 프롬프트 출력.

외부 호출/무거운 의존성 없음 — import-safe."""

from __future__ import annotations

from typing import Dict, List


def format_transcript_text(data: dict) -> str:
    """transcript json -> 사람이 읽는 화자 귀속 텍스트."""
    lines: List[str] = []
    for seg in data.get("segments", []):
        spk = seg.get("speaker", "SPEAKER")
        start = seg.get("start", 0.0)
        end = seg.get("end", 0.0)
        text = seg.get("text", "").strip()
        lines.append(f"[{spk}] {start:.1f}s~{end:.1f}s: {text}")
    return "\n".join(lines)


def _participants(data: dict) -> List[str]:
    seen = []
    for seg in data.get("segments", []):
        spk = seg.get("speaker")
        if spk and spk not in seen:
            seen.append(spk)
    return seen


def generate_local_notes(data: dict, wiki_ctx: Dict[str, str] | None = None) -> str:
    """템플릿 기반 로컬 회의록(markdown). 자동 추출이 불확실한 항목은 [확인 필요]로 둔다.

    없는 내용을 지어내지 않는다 — 결정사항/액션아이템은 사람이 채우거나 --prompt-only로
    AI Agent에게 맡기도록 placeholder만 제공한다(강의자료 규칙)."""
    # json에 키가 있어도 값이 None일 수 있어 'or'로 폴백(None 문자열 표기 방지)
    date = data.get("date") or "[확인 필요]"
    project = data.get("project") or "[확인 필요]"
    source = data.get("audio_path") or "[확인 필요]"
    parts = _participants(data)
    participants_line = ", ".join(parts) if parts else "[확인 필요]"

    md = []
    md.append("---")
    md.append("type: meeting")
    md.append(f"date: {date}")
    md.append(f"project: {project}")
    md.append(f"source_audio: {source}")
    md.append(f"stt_model: {data.get('model', 'Qwen3-ASR-1.7B')}")
    md.append(f"diarization_model: {data.get('diarization_model', 'pyannote/speaker-diarization-3.1')}")
    md.append(f"participants: [{participants_line}]")
    md.append("tags: [meeting, stt, llm-wiki]")
    md.append("---\n")
    md.append(f"# {date} {project} 회의록\n")
    md.append("## 1. 회의 개요")
    md.append(f"- 참석(화자): {participants_line}")
    md.append(f"- 원본 오디오: {source}\n")
    md.append("## 2. 핵심 논의")
    md.append("> 아래는 화자 귀속 전사 원문입니다. 요약은 [확인 필요] — `--prompt-only`로 AI Agent 요약을 권장합니다.\n")
    md.append("```")
    md.append(format_transcript_text(data))
    md.append("```\n")
    md.append("## 3. 결정사항")
    md.append("| 결정 | 근거 | 관련 문서 |")
    md.append("|------|------|-----------|")
    md.append("| [확인 필요] | [확인 필요] | |\n")
    md.append("## 4. 액션아이템")
    md.append("| 담당자 | 작업 | 마감일 | 근거 발화 | 상태 |")
    md.append("|--------|------|--------|-----------|------|")
    md.append("| [확인 필요] | [확인 필요] | [확인 필요] | | 진행 전 |\n")
    md.append("## 5. 리스크 / 확인 필요")
    md.append("- [확인 필요]\n")
    md.append("## 6. 다음 회의 아젠다")
    md.append("- [확인 필요]\n")
    md.append("## 7. 원본 transcript 링크")
    md.append(f"- {source}")
    return "\n".join(md)


def generate_prompt(data: dict, project: str = "My-app") -> str:
    """AI Agent(Claude Code/Codex)용 LLM-Wiki 참조 요약 프롬프트. transcript 포함."""
    transcript = format_transcript_text(data)
    return f"""당신은 회의록 작성 보조자입니다. 다음 LLM-Wiki 파일을 먼저 참고하세요.
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
"""
