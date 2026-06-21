"""Qwen3-ASR-1.7B 래퍼. context biasing(쉼표 구분 키워드)을 지원한다.

모델 로딩은 Qwen3Engine.__init__에서만 일어난다 — 모듈 import는 가볍다."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from .audio import Chunk, TempWav


class Qwen3Engine:
    """Qwen3-ASR-1.7B 음성인식 엔진."""

    MODEL_NAME = "Qwen3-ASR-1.7B"

    def __init__(self, model_path, device, dtype):
        from qwen_asr import Qwen3ASRModel  # 지연 import

        p = Path(model_path)
        if not p.exists():
            raise FileNotFoundError(
                f"{model_path} 가 없습니다. `scripts/download_models.py`를 실행해 Qwen3-ASR 모델을 받으세요."
            )

        def _load(dev, dt):
            return Qwen3ASRModel.from_pretrained(
                str(p), dtype=dt, device_map=dev,
                max_inference_batch_size=8,  # 청크 병렬 배치. 클수록 빠르나 RAM↑
                max_new_tokens=512,          # 한 추론 최대 토큰. 짧으면 긴 발화가 잘림
            )

        try:
            self.model = _load(device, dtype)
            self.device = device
        except Exception as e:  # MPS/GPU 로드 실패 → CPU 폴백(더 나빠지지 않게)
            if device == "cpu":
                raise
            import torch

            print(f"[asr] {device} 로드 실패 → CPU 폴백: {e}")
            self.model = _load("cpu", torch.float32)
            self.device = "cpu"

    @staticmethod
    def _clean_context(context: Optional[str]) -> Optional[str]:
        """context는 쉼표 구분 키워드여야 한다(강의자료 규칙). 공백 정리."""
        if not context:
            return None
        words = [w.strip() for w in context.split(",") if w.strip()]
        return ", ".join(words) if words else None

    def transcribe_file(self, wav_path: str, context: Optional[str] = None) -> str:
        """단일 wav 파일을 전사. context가 있으면 context biasing으로 주입.

        qwen-asr 0.0.6 실제 API: transcribe(audio, context="", language=None, ...).
        (노트북의 initial_prompt 인자는 실제 패키지에 없어 사용하지 않는다.)"""
        kwargs = {"language": "Korean"}
        ctx = self._clean_context(context)
        if ctx:
            kwargs["context"] = ctx
        result = self.model.transcribe(audio=wav_path, **kwargs)
        return result[0].text.strip()

    def transcribe_chunks(
        self, chunks: List[Chunk], sample_rate: int, context: Optional[str] = None
    ) -> str:
        """청크 리스트를 순서대로 전사해 하나의 텍스트로 이어붙인다(진행률 로그 포함)."""
        import time

        parts: List[str] = []
        n = len(chunks)
        t0 = time.time()
        with TempWav() as tmp:
            for i, chunk in enumerate(chunks):
                wav = tmp.write(f"chunk_{i}.wav", chunk.audio, sample_rate)
                parts.append(self.transcribe_file(wav, context=context))
                if (i + 1) % 10 == 0 or i + 1 == n:
                    from .config import hms

                    el = time.time() - t0
                    eta_s = (n - i - 1) / ((i + 1) / el) if el else 0
                    print(f"      [{i+1}/{n} 청크] 경과 {hms(el)} | ETA {hms(eta_s)}", flush=True)
        return " ".join(parts)
