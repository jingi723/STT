"""설정과 경로 규약. torch를 import하지 않아 import-safe하다(디바이스 해석은 함수 호출 시 지연 import)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


# 화자분리 파이프라인 소스. pyannote 공식 모델(speaker-diarization-3.1 / community-1)은 gated라
# 약관 수동 동의가 필요해, gated가 아닌 자체 완결형 미러를 기본값으로 쓴다(pyannote는 MIT 라이선스).
#   - pyannote-community/speaker-diarization-community-1: segmentation+embedding+plda를 repo에 모두 포함,
#     외부 gated 의존성 없음, pyannote.audio 4.x 호환.
DIARIZE_SOURCE = "pyannote-community/speaker-diarization-community-1"


@dataclass
class Config:
    """프로젝트 경로 규약. 모든 경로는 프로젝트 루트 기준."""

    root: Path

    @property
    def diarize_source(self) -> str:
        return DIARIZE_SOURCE

    @property
    def qwen_model_path(self) -> Path:
        return self.root / "models" / "Qwen3-ASR"

    @property
    def diarize_model_path(self) -> Path:
        return self.root / "models" / "pyannote-diarization"

    @property
    def segment_model_path(self) -> Path:
        return self.root / "models" / "pyannote-segmentation"

    @property
    def outputs_dir(self) -> Path:
        return self.root / "outputs"

    @classmethod
    def from_cwd(cls) -> "Config":
        return cls(root=Path.cwd())


def hms(seconds) -> str:
    """초 → 'H:MM:SS' 문자열. 예: 14 → '0:00:14', 5400 → '1:30:00'."""
    s = int(round(float(seconds)))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}"


def resolve_device_dtype():
    """ASR용 디바이스/dtype. CUDA > MPS(애플 GPU) > CPU 순. torch를 지연 import.
    MPS 로드 실패 시 asr.py가 자동으로 CPU로 폴백한다."""
    import torch

    if torch.cuda.is_available():
        return "cuda:0", torch.bfloat16
    if torch.backends.mps.is_available():
        return "mps", torch.float16
    return "cpu", torch.float32


def load_hf_token(root: "Path | None" = None) -> str:
    """HuggingFace 토큰(pyannote 접근용)을 다음 순서로 찾는다:
    1) 환경변수 HF_TOKEN  2) 프로젝트 루트의 .env(HF_TOKEN=...)  3) keys.json(레거시)."""
    import os

    base = Path(root) if root else Path.cwd()

    # 1) 환경변수
    tok = os.environ.get("HF_TOKEN")
    if tok:
        return tok.strip()

    # 2) .env 파일
    env_file = base / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("HF_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")

    # 3) keys.json (레거시 호환)
    legacy = base / "keys.json"
    if legacy.exists():
        token = json.load(open(legacy, encoding="utf-8")).get("hf_token")
        if token:
            return token

    raise FileNotFoundError(
        "HuggingFace 토큰을 찾을 수 없습니다. 다음 중 하나로 설정하세요:\n"
        "  - 환경변수: export HF_TOKEN=hf_...\n"
        "  - .env 파일: 프로젝트 루트에 'HF_TOKEN=hf_...' 한 줄"
    )
