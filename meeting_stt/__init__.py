"""meeting_stt — 로컬 ASR(Qwen3-ASR-1.7B) · 화자분리(pyannote) · LLM-Wiki 회의록 파이프라인.

무거운 의존성(torch, qwen_asr, pyannote)은 각 모듈의 함수/클래스 내부에서 지연 import한다.
따라서 `import meeting_stt`만으로는 모델을 받거나 GPU를 점유하지 않는다.
"""

__version__ = "0.1.0"

__all__ = [
    "config", "audio", "asr", "diarize", "wiki", "notes", "pipeline",
    "capture", "server",
]
