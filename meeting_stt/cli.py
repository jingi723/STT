"""meeting_stt 명령행 인터페이스.

서브커맨드: transcribe / notes / run / init-wiki
무거운 모듈(pipeline)은 각 핸들러 내부에서 import해 `--help`를 가볍게 유지한다."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _add_transcribe_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("audio", help="입력 오디오 파일 (mp3/wav/m4a 등)")
    p.add_argument("--context", default=None,
                   help="context biasing 키워드(쉼표 구분). 예: 'LLM-Wiki, Qwen3-ASR, 김상규'")
    p.add_argument("--num-speakers", type=int, default=None, help="화자 수(알면 지정 시 정확도↑)")
    p.add_argument("--no-diarize", action="store_true", help="화자분리 없이 청크 전사만")
    p.add_argument("--project", default=None, help="프로젝트명(메타에 기록)")
    p.add_argument("--date", default=None, help="회의 날짜(YYYY-MM-DD)")


def cmd_transcribe(args) -> int:
    from .pipeline import transcribe

    data = transcribe(
        audio_path=args.audio, context=args.context, num_speakers=args.num_speakers,
        diarize=not args.no_diarize, project=args.project, date=args.date,
    )
    n = len(data["segments"])
    spk = len({s["speaker"] for s in data["segments"]})
    print(f"전사 완료: {n}개 세그먼트, 화자 {spk}명")
    print(f"  - {data['_md_path']}")
    print(f"  - {data['_json_path']}")
    return 0


def cmd_notes(args) -> int:
    from .notes import generate_local_notes, generate_prompt
    from .wiki import read_context

    jpath = Path(args.transcript_json)
    if not jpath.exists():
        print(f"transcript json을 찾을 수 없습니다: {jpath}", file=sys.stderr)
        return 1
    data = json.loads(jpath.read_text(encoding="utf-8"))
    project = args.project or data.get("project") or "My-app"

    if args.prompt_only:
        out = generate_prompt(data, project=project)
        out_path = jpath.with_suffix(".prompt.md")  # AI 요약용은 별도(요청 시에만)
    elif getattr(args, "ai", False):
        from .notes import generate_ai_notes

        print("claude CLI로 요약 생성 중… (수 분 걸릴 수 있습니다)", file=sys.stderr)
        try:
            out = generate_ai_notes(data, project=project, wiki=args.wiki)
        except Exception as exc:  # CLI 미설치·미로그인·타임아웃 → 템플릿으로 폴백
            print(f"AI 요약 실패({exc}). 템플릿 회의록으로 대체합니다.", file=sys.stderr)
            out = generate_local_notes(data, None)
        out_path = jpath.with_suffix(".md")
    else:
        wiki_ctx = read_context(args.wiki, project=project) if args.wiki else None
        out = generate_local_notes(data, wiki_ctx)
        out_path = jpath.with_suffix(".md")  # 전사 .md에 회의록(전사 포함)으로 덮어씀 → 회의당 한 파일

    out_path.write_text(out, encoding="utf-8")
    print(f"회의록 산출: {out_path}")
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
    print(f"LLM-Wiki 생성 완료: {root}  (project: {args.project})")
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
        print("삭제할 녹음 파일이 없습니다.")
        return 0
    total = sum(f.stat().st_size for f in wavs)
    print(f"녹음 {len(wavs)}개, 총 {total/1e6:.1f}MB")
    if not args.yes:
        print("실제 삭제하려면 --yes 를 붙이세요. (텍스트 결과는 유지됩니다)")
        return 0
    for f in wavs:
        f.unlink()
    print(f"✅ {len(wavs)}개 삭제, {total/1e6:.1f}MB 확보 (전사·회의록은 그대로)")
    return 0


def cmd_apps(args) -> int:
    from .capture import APPTAP, list_app_sources

    if not APPTAP.exists():
        print("앱별 캡처 헬퍼(native/apptap)가 없습니다. 빌드:")
        print("  swiftc -O native/apptap.swift -o native/apptap \\")
        print("    -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit")
        return 1
    for s in list_app_sources():
        print(f"[pid {s['pid']}] {s['name']}  ({s['bundleID']})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="meeting_stt",
        description="로컬 ASR(Qwen3-ASR-1.7B)·화자분리(pyannote)·LLM-Wiki 회의록 파이프라인",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_t = sub.add_parser("transcribe", help="오디오 → 화자 귀속 transcript")
    _add_transcribe_args(p_t)
    p_t.set_defaults(func=cmd_transcribe)

    p_n = sub.add_parser("notes", help="transcript → 회의록(또는 AI 요약 프롬프트)")
    p_n.add_argument("transcript_json", help="transcribe가 만든 outputs/{이름}.json")
    p_n.add_argument("--wiki", default=None, help="LLM-Wiki 경로(참조 맥락 로드)")
    p_n.add_argument("--project", default=None, help="프로젝트명")
    p_n.add_argument("--prompt-only", action="store_true",
                     help="회의록 대신 AI Agent용 요약 프롬프트를 출력")
    p_n.add_argument("--ai", action="store_true",
                     help="claude CLI(로그인 계정)로 회의록을 자동 요약. API 키 불필요")
    p_n.set_defaults(func=cmd_notes)

    p_r = sub.add_parser("run", help="transcribe + notes 전체 실행")
    _add_transcribe_args(p_r)
    p_r.add_argument("--wiki", default=None, help="LLM-Wiki 경로")
    p_r.add_argument("--prompt-only", action="store_true", help="AI 요약 프롬프트 출력")
    p_r.add_argument("--ai", action="store_true", help="claude CLI로 회의록 자동 요약")
    p_r.set_defaults(func=cmd_run)

    p_w = sub.add_parser("init-wiki", help="LLM-Wiki 폴더 구조 스캐폴딩")
    p_w.add_argument("path", help="생성할 LLM-Wiki 경로")
    p_w.add_argument("--project", default="My-app", help="초기 프로젝트명")
    p_w.set_defaults(func=cmd_init_wiki)

    p_d = sub.add_parser("dashboard", help="로컬 웹 대시보드 실행(녹음·장치선택·전사·회의록)")
    p_d.add_argument("--host", default="127.0.0.1", help="바인드 호스트")
    p_d.add_argument("--port", type=int, default=8000, help="포트")
    p_d.set_defaults(func=cmd_dashboard)

    p_dev = sub.add_parser("devices", help="입력 오디오 장치 목록 출력")
    p_dev.set_defaults(func=cmd_devices)

    p_app = sub.add_parser("apps", help="앱별 캡처 가능한 앱(프로세스) 목록 출력 (macOS)")
    p_app.set_defaults(func=cmd_apps)

    p_clean = sub.add_parser("clean-audio", help="녹음 음성(.wav) 삭제로 공간 확보(텍스트 유지)")
    p_clean.add_argument("--yes", action="store_true", help="실제 삭제 실행")
    p_clean.set_defaults(func=cmd_clean_audio)

    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
