"""pyannote 화자분리. 모델 로딩·로그인은 Diarizer.__init__에서만 수행한다."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional


@dataclass
class Segment:
    """화자분리 세그먼트. pipeline의 화자 귀속 입력 구조."""

    speaker: str
    start: float
    end: float
    text: str = ""


class Diarizer:
    """pyannote speaker-diarization-3.1 래퍼."""

    MODEL_NAME = "pyannote/speaker-diarization-3.1"

    def __init__(self, source, hf_token: str, device: str):
        """source: 로컬 파이프라인 경로 또는 HF repo id(비-gated 미러).
        repo id면 pyannote가 참조 모델(segmentation/embedding)을 받아 HF 캐시에 둔다(이후 오프라인)."""
        import torch  # 지연 import
        from huggingface_hub import login
        from pyannote.audio import Pipeline

        login(token=hf_token, add_to_git_credential=False)
        p = Path(str(source))
        target = str(p) if p.exists() else str(source)  # 로컬 경로 우선, 없으면 repo id
        self.pipeline = Pipeline.from_pretrained(target, token=hf_token)
        if self.pipeline is None:
            raise RuntimeError(
                f"화자분리 파이프라인 로드 실패: {target}. 네트워크/접근 권한을 확인하세요."
            )
        # 1초 이하 묵음은 같은 발화로 묶는다(검증된 값). 파이프라인 구조에 따라 속성이
        # 없을 수 있어 방어적으로 설정한다.
        try:
            self.pipeline.segmentation.min_duration_off = 1.0
        except AttributeError:
            pass
        self.pipeline = self.pipeline.to(torch.device(device))

    def run(self, audio, sample_rate: int, num_speakers: Optional[int] = None) -> List[Segment]:
        """오디오를 화자별 세그먼트로 분리. 화자 수를 알면 num_speakers로 정확도 향상."""
        import torch

        waveform = torch.tensor(audio).unsqueeze(0).float()
        params = {"waveform": waveform, "sample_rate": sample_rate}
        kwargs = {"num_speakers": num_speakers} if num_speakers else {}
        result = self.pipeline(params, **kwargs)
        # pyannote 4.x는 DiarizeOutput(.speaker_diarization=Annotation)을, 3.x는 Annotation을 반환.
        annotation = getattr(result, "speaker_diarization", result)
        segments: List[Segment] = []
        for turn, _, speaker in annotation.itertracks(yield_label=True):
            segments.append(Segment(speaker=speaker, start=turn.start, end=turn.end))
        return segments
