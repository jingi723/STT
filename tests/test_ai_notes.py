"""generate_ai_notes 자체 점검: claude CLI를 가짜로 세워 호출/폴백 경로를 확인."""
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from meeting_stt.notes import generate_ai_notes  # noqa: E402

DATA = {
    "date": "2026-08-15",
    "project": "STT",
    "segments": [
        {"speaker": "SPEAKER_00", "start": 0.0, "end": 2.0, "text": "다음 주까지 배포합시다."},
        {"speaker": "SPEAKER_01", "start": 2.0, "end": 4.0, "text": "네, 제가 맡겠습니다."},
    ],
}


def _fake_claude(tmp: Path, body: str, rc: int = 0) -> None:
    exe = tmp / "claude"
    exe.write_text(f"#!/bin/sh\ncat > /dev/null\nprintf '%s' '{body}'\nexit {rc}\n")
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    os.environ["PATH"] = f"{tmp}:{os.environ['PATH']}"


def main() -> None:
    original_path = os.environ["PATH"]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _fake_claude(tmp, "# 회의록\n- 결정: 다음 주 배포")
        out = generate_ai_notes(DATA, project="STT")
        assert "# 회의록" in out, out
        assert "다음 주까지 배포합시다" in out, "전사 원문이 붙어야 함"

        os.environ["PATH"] = original_path
        _fake_claude(Path(td), "", rc=1)  # 빈 출력 + 실패 코드
        try:
            generate_ai_notes(DATA)
            raise AssertionError("실패 시 RuntimeError를 던져야 함")
        except RuntimeError:
            pass
    os.environ["PATH"] = original_path

    # CLI --ai 폴백: claude가 없어도 템플릿 회의록이 나와야 한다
    with tempfile.TemporaryDirectory() as td:
        jpath = Path(td) / "sample.json"
        jpath.write_text(json.dumps(DATA), encoding="utf-8")
        env = {**os.environ, "PATH": "/nonexistent"}
        rc = subprocess.run(
            [sys.executable, "-m", "meeting_stt", "notes", str(jpath), "--ai"],
            cwd=Path(__file__).resolve().parents[1], env=env, capture_output=True, text=True,
        )
        assert rc.returncode == 0, rc.stderr
        assert "액션아이템" in jpath.with_suffix(".md").read_text(encoding="utf-8")

    print("ok")


if __name__ == "__main__":
    main()
