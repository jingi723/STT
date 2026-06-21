"""통합 파이프라인: 오디오 -> (화자분리) -> Qwen3 전사 -> 화자 귀속 transcript 저장."""

from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path
from typing import List, Optional

from . import audio as audio_mod
from .config import Config, hms, load_hf_token, resolve_device_dtype
from .diarize import Segment


def _build_data(audio_path, segments, project, date, context, diarize) -> dict:
    return {
        "audio_path": str(audio_path),
        "model": "Qwen3-ASR-1.7B",
        "diarization_model": "pyannote-community/speaker-diarization-community-1" if diarize else None,
        "context": context,
        "diarized": diarize,
        "project": project,
        "date": date,
        "segments": [asdict(s) for s in segments],
    }


def _dump_partial(path: Path, audio_path, segments, project, date, context, diarize) -> None:
    """진행 중 중간저장 — 끊겨도 다음 실행에서 이어할 수 있게 한다."""
    data = _build_data(audio_path, segments, project, date, context, diarize)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def _save_outputs(config: Config, stem: str, data: dict) -> tuple[Path, Path]:
    """회의 1건당 텍스트 2개만 저장: {stem}.json(데이터) + {stem}.md(사람용).
    무거운 음성(.wav)은 outputs/recordings/ 에 따로 있어 텍스트와 분리된다."""
    config.outputs_dir.mkdir(parents=True, exist_ok=True)
    json_path = config.outputs_dir / f"{stem}.json"
    md_path = config.outputs_dir / f"{stem}.md"

    json_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    from .notes import format_transcript_text

    md = [f"# {stem} 화자 귀속 전사\n", f"- 오디오: {data['audio_path']}",
          f"- 모델: {data['model']}", f"- context: {data.get('context') or '없음'}",
          f"- 화자분리: {'예' if data['diarized'] else '아니오'}\n", "```",
          format_transcript_text(data), "```",
          "\n> 회의록은 `meeting_stt notes` 또는 대시보드의 회의록 버튼으로 이 파일에 추가됩니다."]
    md_path.write_text("\n".join(md), encoding="utf-8")
    return json_path, md_path


def transcribe(
    audio_path: str,
    context: Optional[str] = None,
    num_speakers: Optional[int] = None,
    diarize: bool = True,
    project: Optional[str] = None,
    date: Optional[str] = None,
    config: Optional[Config] = None,
) -> dict:
    """전체 전사 파이프라인 실행. 화자 귀속 transcript dict를 반환하고 outputs/에 저장.

    - ASR(Qwen3)은 GPU(MPS)가 있으면 GPU로, 없으면 CPU로. 화자분리(pyannote)는 안정성 위해 CPU.
    - 긴 음성 대비: 구간별 진행 로그 + 중간저장(.partial.json) + 재시작 시 이어하기."""
    import time

    config = config or Config.from_cwd()
    device, dtype = resolve_device_dtype()  # ASR 디바이스(MPS 우선)
    stem = Path(audio_path).stem
    config.outputs_dir.mkdir(parents=True, exist_ok=True)

    print(f"[1/3] 오디오 로딩: {audio_path}")
    audio, sr = audio_mod.load_audio(audio_path)
    print(f"      길이 {len(audio)/sr/60:.1f}분, ASR 디바이스={device}")

    from .asr import Qwen3Engine

    engine = Qwen3Engine(config.qwen_model_path, device, dtype)

    segments: List[Segment] = []
    if diarize:
        from .diarize import Diarizer

        token = load_hf_token(config.root)
        print(f"[2/3] 화자분리(pyannote) 실행 중... (device={device})")
        diarizer = Diarizer(config.diarize_source, token, device)  # MPS 우선, 실패 시 CPU 폴백
        segments = diarizer.run(audio, sr, num_speakers=num_speakers)
        n = len(segments)
        print(f"      세그먼트 {n}개, 화자 {len({s.speaker for s in segments})}명")

        # 이전 진행분(.partial.json) 이어하기
        partial_path = config.outputs_dir / f"{stem}.partial.json"
        done: dict = {}
        if partial_path.exists():
            try:
                prev = json.loads(partial_path.read_text(encoding="utf-8"))
                if prev.get("audio_path") == str(audio_path) and len(prev.get("segments", [])) == n:
                    for i, s in enumerate(prev["segments"]):
                        if s.get("text"):
                            done[i] = s["text"]
                    if done:
                        print(f"      이어하기: 이전 {len(done)}/{n} 재사용")
            except Exception:
                pass

        print(f"[3/3] 전사 시작 ({n}개 구간)")
        t0 = time.time()
        with audio_mod.TempWav() as tmp:
            for i, seg in enumerate(segments):
                if i in done:
                    seg.text = done[i]
                    continue
                clip = audio_mod.slice_audio(audio, sr, seg.start, seg.end)
                if len(clip) == 0:
                    continue
                wav = tmp.write(f"seg_{i}.wav", clip, sr)
                seg.text = engine.transcribe_file(wav, context=context)
                if (i + 1) % 5 == 0 or i + 1 == n:
                    el = time.time() - t0
                    rate = (i + 1) / el if el else 0
                    eta_s = (n - i - 1) / rate if rate else 0
                    print(f"      [{i+1}/{n}] {hms(seg.end)} 지점 | 경과 {hms(el)} | ETA {hms(eta_s)}", flush=True)
                    # 중간저장(끊겨도 보존)
                    _dump_partial(partial_path, audio_path, segments, project, date, context, diarize)
        partial_path.unlink(missing_ok=True)  # 완료 → partial 제거
    else:
        # 화자분리 없이 30초/2초 오버랩 청킹 전사 → 단일 화자 세그먼트로 표현
        chunks = audio_mod.chunk_audio(audio, sr)
        text = engine.transcribe_chunks(chunks, sr, context=context)
        total = len(audio) / sr
        segments = [Segment(speaker="SPEAKER_00", start=0.0, end=total, text=text)]

    data = _build_data(audio_path, segments, project, date, context, diarize)
    json_path, md_path = _save_outputs(config, stem, data)
    data["_json_path"] = str(json_path)
    data["_md_path"] = str(md_path)
    return data
