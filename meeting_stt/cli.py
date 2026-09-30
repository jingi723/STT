"""meeting_stt 명령행 인터페이스.

서브커맨드: transcribe / notes / run / init-wiki
무거운 모듈(pipeline)은 각 핸들러 내부에서 import해 `--help`를 가볍게 유지한다."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _add_transcribe_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("audio", help="Input audio file (mp3, wav, m4a, etc.)")
    p.add_argument("--context", default=None,
                   help="Comma-separated context keywords, e.g. 'LLM-Wiki, Qwen3-ASR, Alex'")
    p.add_argument("--num-speakers", type=int, default=None, help="Number of speakers, if known")
    p.add_argument("--no-diarize", action="store_true", help="Transcribe chunks without speaker diarization")
    p.add_argument("--project", default=None, help="Project name (saved in metadata)")
    p.add_argument("--date", default=None, help="Meeting date (YYYY-MM-DD)")


def cmd_transcribe(args) -> int:
    from .pipeline import transcribe

    data = transcribe(
        audio_path=args.audio, context=args.context, num_speakers=args.num_speakers,
        diarize=not args.no_diarize, project=args.project, date=args.date,
    )
    n = len(data["segments"])
    spk = len({s["speaker"] for s in data["segments"]})
    print(f"Transcription complete: {n} segments, {spk} speakers")
    print(f"  - {data['_md_path']}")
    print(f"  - {data['_json_path']}")
    return 0


def cmd_notes(args) -> int:
    from .notes import generate_local_notes, generate_prompt
    from .wiki import read_context

    jpath = Path(args.transcript_json)
    if not jpath.exists():
        print(f"Transcript JSON not found: {jpath}", file=sys.stderr)
        return 1
    data = json.loads(jpath.read_text(encoding="utf-8"))
    project = args.project or data.get("project") or "My-app"

    if args.prompt_only:
        out = generate_prompt(data, project=project)
        out_path = jpath.with_suffix(".prompt.md")  # AI 요약용은 별도(요청 시에만)
    elif getattr(args, "ai", False):
        from .notes import generate_ai_notes

        print("Generating notes with Claude CLI… (this may take a few minutes)", file=sys.stderr)
        try:
            out = generate_ai_notes(data, project=project, wiki=args.wiki)
        except Exception as exc:  # CLI 미설치·미로그인·타임아웃 → 템플릿으로 폴백
            print(f"AI summary failed({exc}). Falling back to template notes.", file=sys.stderr)
            out = generate_local_notes(data, None)
        out_path = jpath.with_suffix(".md")
    else:
        wiki_ctx = read_context(args.wiki, project=project) if args.wiki else None
        out = generate_local_notes(data, wiki_ctx)
        out_path = jpath.with_suffix(".md")  # 전사 .md에 회의록(전사 포함)으로 덮어씀 → 회의당 한 파일

    out_path.write_text(out, encoding="utf-8")
    print(f"Meeting notes saved: {out_path}")
    return 0


def cmd_run(args) -> int:
    rc = cmd_transcribe(args)
    if rc != 0:
        return rc
    from .config import Config

    stem = Path(args.audio).stem
    jpath = Config.from_cwd().outputs_dir / f"{stem}.json"
    notes_args = argparse.Namespace(
        transcript_json=str(jpath), wiki=args.wiki, project=args.project,
        prompt_only=args.prompt_only, ai=getattr(args, "ai", False),
    )
    return cmd_notes(notes_args)


def cmd_init_wiki(args) -> int:
    from .wiki import init_wiki

    root = init_wiki(args.path, project=args.project)
    print(f"Created LLM-Wiki: {root}  (project: {args.project})")
    return 0


def cmd_dashboard(args) -> int:
    from .server import run_server

    run_server(host=args.host, port=args.port)
    return 0


def cmd_devices(args) -> int:
    from .capture import list_input_devices

    for d in list_input_devices():
        print(f"[{d['index']}] {d['name']}  ({d['channels']}ch, {d['default_samplerate']}Hz)")
    return 0


def cmd_clean_audio(args) -> int:
    """무거운 녹음 음성(outputs/recordings/**/*.wav)을 삭제해 공간 확보. 텍스트(.md/.json)는 보존."""
    from .config import Config

    rec_dir = Config.from_cwd().outputs_dir / "recordings"
    wavs = sorted(rec_dir.rglob("*.wav")) if rec_dir.exists() else []
    if not wavs:
        print("No recordings to delete.")
        return 0
    total = sum(f.stat().st_size for f in wavs)
    print(f"{len(wavs)} recordings, total {total/1e6:.1f}MB")
    if not args.yes:
        print("Add --yes to delete recordings. Text results are preserved.")
        return 0
    for f in wavs:
        f.unlink()
    print(f"✅ {len(wavs)} deleted, {total/1e6:.1f}MB freed (transcripts and notes preserved)")
    return 0


def cmd_apps(args) -> int:
    from .capture import APPTAP, list_app_sources

    if not APPTAP.exists():
        print("App capture helper (native/apptap) is missing. Build it with:")
        print("  swiftc -O native/apptap.swift -o native/apptap \\")
        print("    -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit")
        return 1
    for s in list_app_sources():
        print(f"[pid {s['pid']}] {s['name']}  ({s['bundleID']})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="meeting_stt",
        description="Local transcription (Qwen3-ASR-1.7B), speaker diarization (pyannote), and meeting notes",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_t = sub.add_parser("transcribe", help="Audio to speaker-attributed transcript")
    _add_transcribe_args(p_t)
    p_t.set_defaults(func=cmd_transcribe)

    p_n = sub.add_parser("notes", help="Transcript to meeting notes or AI summary prompt")
    p_n.add_argument("transcript_json", help="outputs/{name}.json created by transcribe")
    p_n.add_argument("--wiki", default=None, help="LLM-Wiki path for reference context")
    p_n.add_argument("--project", default=None, help="Project name")
    p_n.add_argument("--prompt-only", action="store_true",
                     help="Generate an AI summary prompt instead of notes")
    p_n.add_argument("--ai", action="store_true",
                     help="Generate AI notes with your signed-in Claude CLI account")
    p_n.set_defaults(func=cmd_notes)

    p_r = sub.add_parser("run", help="Run transcription and notes generation")
    _add_transcribe_args(p_r)
    p_r.add_argument("--wiki", default=None, help="LLM-Wiki path")
    p_r.add_argument("--prompt-only", action="store_true", help="Generate an AI summary prompt")
    p_r.add_argument("--ai", action="store_true", help="Generate AI notes using Claude CLI")
    p_r.set_defaults(func=cmd_run)

    p_w = sub.add_parser("init-wiki", help="Create an LLM-Wiki directory scaffold")
    p_w.add_argument("path", help="Destination LLM-Wiki path")
    p_w.add_argument("--project", default="My-app", help="Initial project name")
    p_w.set_defaults(func=cmd_init_wiki)

    p_d = sub.add_parser("dashboard", help="Start the local recording, transcription, and notes dashboard")
    p_d.add_argument("--host", default="127.0.0.1", help="Bind host")
    p_d.add_argument("--port", type=int, default=8000, help="Port")
    p_d.set_defaults(func=cmd_dashboard)

    p_dev = sub.add_parser("devices", help="List audio input devices")
    p_dev.set_defaults(func=cmd_devices)

    p_app = sub.add_parser("apps", help="List apps available for audio capture (macOS)")
    p_app.set_defaults(func=cmd_apps)

    p_clean = sub.add_parser("clean-audio", help="Free disk space by deleting WAV recordings (keep text)")
    p_clean.add_argument("--yes", action="store_true", help="Confirm deletion")
    p_clean.set_defaults(func=cmd_clean_audio)

    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
