"""통합 파이프라인: 오디오 -> (화자분리) -> Qwen3 전사 -> 화자 귀속 transcript 저장."""

from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path
from typing import List, Optional

from . import audio as audio_mod
from .config import Config, load_hf_token, resolve_device_dtype
from .diarize import Segment


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
    """전체 전사 파이프라인 실행. 화자 귀속 transcript dict를 반환하고 outputs/에 저장."""
    config = config or Config.from_cwd()
    device, dtype = resolve_device_dtype()

    audio, sr = audio_mod.load_audio(audio_path)

    from .asr import Qwen3Engine

    engine = Qwen3Engine(config.qwen_model_path, device, dtype)

    segments: List[Segment] = []
    if diarize:
        from .diarize import Diarizer

        token = load_hf_token(config.root)
        diarizer = Diarizer(config.diarize_source, token, device)
        segments = diarizer.run(audio, sr, num_speakers=num_speakers)

        with audio_mod.TempWav() as tmp:
            for i, seg in enumerate(segments):
                clip = audio_mod.slice_audio(audio, sr, seg.start, seg.end)
                if len(clip) == 0:
                    continue
                wav = tmp.write(f"seg_{i}.wav", clip, sr)
                seg.text = engine.transcribe_file(wav, context=context)
    else:
        # 화자분리 없이 30초/2초 오버랩 청킹 전사 → 단일 화자 세그먼트로 표현
        chunks = audio_mod.chunk_audio(audio, sr)
        text = engine.transcribe_chunks(chunks, sr, context=context)
        total = len(audio) / sr
        segments = [Segment(speaker="SPEAKER_00", start=0.0, end=total, text=text)]

    data = {
        "audio_path": str(audio_path),
        "model": Qwen3Engine.MODEL_NAME,
        "diarization_model": "pyannote/speaker-diarization-3.1" if diarize else None,
        "context": context,
        "diarized": diarize,
        "project": project,
        "date": date,
        "segments": [asdict(s) for s in segments],
    }

    stem = Path(audio_path).stem
    json_path, md_path = _save_outputs(config, stem, data)
    data["_json_path"] = str(json_path)
    data["_md_path"] = str(md_path)
    return data
