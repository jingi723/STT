"""Notes generation tests. Never invoke a real AI service."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from meeting_stt.cli import main
from meeting_stt.notes import generate_ai_notes

DATA = {
    "date": "2026-09-30", "project": "STT",
    "segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 2, "text": "Let's ship next week."}],
}


class AINotesTests(unittest.TestCase):
    @patch("meeting_stt.notes._claude_cli", return_value="fake-claude")
    @patch("subprocess.run")
    def test_summary_preserves_transcript(self, run, _cli):
        run.return_value = subprocess.CompletedProcess([], 0, "# Meeting notes\nShip next week.", "")
        result = generate_ai_notes(DATA)
        self.assertIn("# Meeting notes", result)
        self.assertIn("## Original transcript", result)
        self.assertIn(DATA["segments"][0]["text"], result)
        self.assertIn("--strict-mcp-config", run.call_args.args[0])
        self.assertIn("write meeting notes in English", run.call_args.kwargs["input"])

    @patch("meeting_stt.notes._claude_cli", return_value="fake-claude")
    @patch("subprocess.run")
    def test_failure_and_empty_response(self, run, _cli):
        for code in [0, 1]:
            with self.subTest(code=code):
                run.return_value = subprocess.CompletedProcess([], code, "", "test error")
                with self.assertRaises(RuntimeError):
                    generate_ai_notes(DATA)

    @patch("meeting_stt.notes.generate_ai_notes", side_effect=RuntimeError("AI unavailable"))
    def test_cli_falls_back_to_local_notes(self, _generate):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.json"
            path.write_text(json.dumps(DATA), encoding="utf-8")
            self.assertEqual(main(["notes", str(path), "--ai"]), 0)
            output = path.with_suffix(".md").read_text(encoding="utf-8")
            self.assertIn("## 4. Action items", output)
            self.assertIn(DATA["segments"][0]["text"], output)


if __name__ == "__main__":
    unittest.main()
