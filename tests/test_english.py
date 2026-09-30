"""Guard the public English interface while preserving multilingual user content."""
import ast
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from meeting_stt.cli import build_parser
from meeting_stt.notes import generate_local_notes, generate_prompt
from meeting_stt.wiki import init_wiki

HANGUL = re.compile(r"[가-힣]")


class EnglishInterfaceTests(unittest.TestCase):
    def test_python_runtime_messages_are_english(self):
        for path in (ROOT / "meeting_stt").glob("*.py"):
            tree = ast.parse(path.read_text())
            docstrings = {id(node.value) for node in ast.walk(tree)
                          if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant)}
            for node in ast.walk(tree):
                if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings:
                    self.assertIsNone(HANGUL.search(node.value), f"{path.name}:{node.lineno}: {node.value!r}")

    def test_swift_user_messages_are_english(self):
        for path in (ROOT / "macos/Sources/MeetingSTTApp").glob("*.swift"):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if not line.lstrip().startswith("//"):
                    self.assertIsNone(HANGUL.search(line), f"{path.name}:{number}")

    def test_capture_readiness_protocol_matches(self):
        helper = (ROOT / "native/apptap.swift").read_text()
        runner = (ROOT / "macos/Sources/MeetingSTTApp/ProcessRunner.swift").read_text()
        marker = re.search(r'line.contains\("([^"]+)"\)', runner).group(1)
        self.assertIn(f"[apptap] {marker} (", helper)
        self.assertIn('"START_HOST ', helper)
        self.assertIn('"START_HOST ', runner)

    def test_cli_and_templates_preserve_original_speech(self):
        self.assertIn("Local transcription", build_parser().format_help())
        data = {"segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 1, "text": "원문은 보존합니다."}]}
        self.assertIn("## 4. Action items", generate_local_notes(data))
        self.assertIn("원문은 보존합니다.", generate_local_notes(data))
        self.assertIn("write meeting notes in English", generate_prompt(data))
        with tempfile.TemporaryDirectory() as directory:
            init_wiki(directory, project="Example")
            for path in Path(directory).rglob("*.md"):
                self.assertIsNone(HANGUL.search(path.read_text()), path)

    def test_english_bundle_and_dashboard(self):
        self.assertTrue((ROOT / "Meeting STT.app/Contents/Info.plist").exists())
        html = (ROOT / "meeting_stt/web/index.html").read_text()
        html = re.sub(r"/\*.*?\*/|<!--.*?-->", "", html, flags=re.S)
        html = re.sub(r"//[^\n]*", "", html)
        self.assertIn('<html lang="en">', html)
        self.assertIsNone(HANGUL.search(html))


if __name__ == "__main__":
    unittest.main()
