"""모델 다운로드 — Qwen3-ASR(로컬) + 화자분리 파이프라인(비-gated 미러, HF 캐시 워밍).

화자분리는 gated인 pyannote 공식 모델 대신 비-gated 자체완결 미러
(pyannote-community/speaker-diarization-community-1)를 HF 캐시로 워밍한다(pyannote는 MIT 라이선스).

사용(어느 위치에서 실행해도 됨): STT_env/bin/python scripts/download_models.py
"""
import json
import os
import sys
from pathlib import Path

# 프로젝트 루트를 기준으로 동작(실행 위치 무관): .env/models 해석 + meeting_stt import
ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
sys.path.insert(0, str(ROOT))

from huggingface_hub import login, snapshot_download

from meeting_stt.config import DIARIZE_SOURCE, load_hf_token

token = load_hf_token(ROOT)
login(token=token, add_to_git_credential=False)
print("Signed in to Hugging Face\n")

# 1) Qwen3-ASR (로컬 디렉토리)
qwen_dir = Path("models/Qwen3-ASR")
if (qwen_dir / "config.json").exists():
    print("✅ Qwen/Qwen3-ASR-1.7B → already downloaded")
else:
    print("⬇️  Qwen/Qwen3-ASR-1.7B downloading...")
    snapshot_download(repo_id="Qwen/Qwen3-ASR-1.7B", local_dir=str(qwen_dir))
    print("✅ Qwen3-ASR ready")

# 2) 화자분리 파이프라인 워밍 — Pipeline.from_pretrained가 참조 모델까지 캐시에 받음
print(f"\n⬇️  Loading/downloading speaker diarization pipeline: {DIARIZE_SOURCE}")
from pyannote.audio import Pipeline

pipe = Pipeline.from_pretrained(DIARIZE_SOURCE, token=token)
if pipe is None:
    raise SystemExit("❌ Could not load diarization pipeline (check connection and permissions)")
print("✅ Diarization pipeline ready (segmentation and embedding cached)")

print("\nAll models ready")
