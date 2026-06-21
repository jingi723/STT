"""오디오 로딩·청킹·wav 쓰기. soundfile을 상단에서 import해 NameError를 방지한다.

librosa/soundfile은 비교적 가벼우나, 환경 미설치 시에도 import meeting_stt가 가능하도록
무거운 호출은 함수 내부에서 수행한다(모듈 최상단 import는 가볍게 유지)."""

from __future__ import annotations

import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import List


@dataclass
class Chunk:
    """오디오 청크 한 조각."""

    audio: "object"  # np.ndarray (지연 의존)
    start_sec: float
    end_sec: float


def load_audio(path: str, sr: int | None = None):
    """모노 오디오를 로드해 (audio, sample_rate) 반환."""
    import librosa

    if not Path(path).exists():
        raise FileNotFoundError(f"오디오 파일을 찾을 수 없습니다: {path}")
    audio, sample_rate = librosa.load(path, sr=sr, mono=True)
    return audio, sample_rate


def chunk_audio(audio, sample_rate: int, chunk_sec: int = 30, overlap_sec: int = 2) -> List[Chunk]:
    """30초 단위 / 2초 오버랩으로 청킹(검증된 기본값)."""
    step_sec = chunk_sec - overlap_sec
    chunk_samples = int(chunk_sec * sample_rate)
    step_samples = int(step_sec * sample_rate)
    chunks: List[Chunk] = []
    start = 0
    while start < len(audio):
        end = min(start + chunk_samples, len(audio))
        chunks.append(
            Chunk(
                audio=audio[start:end],
                start_sec=start / sample_rate,
                end_sec=end / sample_rate,
            )
        )
        start += step_samples
    return chunks


def slice_audio(audio, sample_rate: int, start: float, end: float):
    """[start, end] 초 구간 오디오를 잘라 반환."""
    return audio[int(start * sample_rate) : int(end * sample_rate)]


def write_wav(path: str, audio, sample_rate: int) -> None:
    """wav 파일 쓰기. soundfile은 함수 내부에서 import(미설치 환경 import-safe).
    상위 폴더가 없으면 생성해 'System error'(디렉토리 없음)를 방지한다."""
    import soundfile as sf

    Path(path).parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, audio, sample_rate)


class TempWav:
    """임시 디렉토리에 청크 wav를 쓰는 컨텍스트 매니저."""

    def __enter__(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        return self

    def write(self, name: str, audio, sample_rate: int) -> str:
        path = str(self.dir / name)
        write_wav(path, audio, sample_rate)
        return path

    def __exit__(self, *exc):
        self._tmp.cleanup()
