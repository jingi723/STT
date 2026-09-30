"""회의록 생성. 두 경로: (1) 템플릿 기반 로컬 생성, (2) AI Agent용 요약 프롬프트 출력.

외부 호출/무거운 의존성 없음 — import-safe."""

from __future__ import annotations

from typing import Dict, List


def format_transcript_text(data: dict) -> str:
    """transcript json -> 사람이 읽는 화자 귀속 텍스트. 타임스탬프는 시:분:초."""
    from .config import hms

    lines: List[str] = []
    for seg in data.get("segments", []):
        spk = seg.get("speaker", "SPEAKER")
        start = seg.get("start", 0.0)
        end = seg.get("end", 0.0)
        text = seg.get("text", "").strip()
        lines.append(f"[{spk}] {hms(start)}~{hms(end)}: {text}")
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
    date = data.get("date") or "[Needs confirmation]"
    project = data.get("project") or "[Needs confirmation]"
    source = data.get("audio_path") or "[Needs confirmation]"
    parts = _participants(data)
    participants_line = ", ".join(parts) if parts else "[Needs confirmation]"

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
    md.append(f"# {date} {project} Meeting notes\n")
    md.append("## 1. Meeting overview")
    md.append(f"- Participants (speakers): {participants_line}")
    md.append(f"- Source audio: {source}\n")
    md.append("## 2. Key discussion")
    md.append("> The original speaker-attributed transcript follows. Summary: [Needs confirmation]. Use `--prompt-only` to prepare an AI summary prompt.\n")
    md.append("```")
    md.append(format_transcript_text(data))
    md.append("```\n")
    md.append("## 3. Decisions")
    md.append("| Decision | Evidence | Related documents |")
    md.append("|------|------|-----------|")
    md.append("| [Needs confirmation] | [Needs confirmation] | |\n")
    md.append("## 4. Action items")
    md.append("| Owner | Task | Deadline | Supporting statement | Status |")
    md.append("|--------|------|--------|-----------|------|")
    md.append("| [Needs confirmation] | [Needs confirmation] | [Needs confirmation] | | Not started |\n")
    md.append("## 5. Risks / Needs confirmation")
    md.append("- [Needs confirmation]\n")
    md.append("## 6. Next meeting agenda")
    md.append("- [Needs confirmation]\n")
    md.append("## 7. Source transcript link")
    md.append(f"- {source}")
    return "\n".join(md)


def _claude_cli() -> str:
    """Claude Code CLI 경로. GUI 앱은 PATH가 빈약해 홈 설치 경로까지 직접 확인한다."""
    import os
    import shutil

    found = shutil.which("claude")
    if found:
        return found
    for cand in (os.path.expanduser("~/.local/bin/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    raise RuntimeError("Claude CLI was not found. Install Claude Code and sign in with `claude`.")


def generate_ai_notes(data: dict, project: str = "My-app", wiki: str | None = None,
                      timeout: int = 900) -> str:
    """`claude -p`로 자동 요약. 기존 Claude Code 로그인을 쓰므로 API 키가 필요 없다.

    전사 원문은 회의당 한 파일 규약대로 요약 뒤에 붙인다."""
    import subprocess
    import tempfile

    prompt = generate_prompt(data, project=project)
    if wiki:
        prompt = f"LLM-Wiki root: {wiki}\n\n{prompt}"
    else:
        # 위키가 없으면 참고 파일을 찾아 홈 디렉터리·외부 서비스를 뒤지는 것을 막는다
        prompt = ("No LLM-Wiki is available. Skip the wiki reference steps below and "
                  "write only from the transcript, without browsing files or external sources.\n\n") + prompt

    proc = subprocess.run(
        [_claude_cli(), "-p", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}'],
        input=prompt,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=tempfile.gettempdir(),  # 저장소 CLAUDE.md/스킬이 요약 프롬프트에 섞이지 않도록
    )
    if proc.returncode != 0:
        raise RuntimeError(f"claude CLI failed(rc={proc.returncode}): {proc.stderr.strip()[:500]}")
    notes = proc.stdout.strip()
    if not notes:
        raise RuntimeError("Claude CLI returned an empty response. Check your `claude` sign-in status.")
    return f"{notes}\n\n---\n\n## Original transcript\n\n```\n{format_transcript_text(data)}\n```\n"


def generate_prompt(data: dict, project: str = "My-app") -> str:
    """AI Agent(Claude Code/Codex)용 LLM-Wiki 참조 요약 프롬프트. transcript 포함."""
    transcript = format_transcript_text(data)
    return f"""You are a meeting notes assistant. First consult the following LLM-Wiki files.
- 02_Projects/{project}/project-overview.md
- 02_Projects/{project}/glossary.md
- 02_Projects/{project}/decisions.md
- 03_People/team-members.md

Then read the transcript below and write meeting notes in English. Preserve names and quoted statements in their original language.

Requirements:
- Do not invent facts. Mark uncertain information as [Needs confirmation].
- Separate decisions and action items. Include an owner, task, deadline, and supporting statement for each action item.
- Mark conflicts with prior decisions as [Possible conflict with an earlier decision].
- List new terms separately as suggested glossary additions.
- Map anonymous labels such as SPEAKER_00 using team-members.md only when certain; otherwise keep the labels.
- Return Markdown following 04_Templates/meeting-template.md.

--- TRANSCRIPT ---
{transcript}
"""
