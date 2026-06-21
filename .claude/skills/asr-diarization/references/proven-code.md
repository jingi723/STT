# 검증된 코드 패턴 (test.ipynb 기반, Qwen3 전용)

`test.ipynb`에서 동작이 확인된 로직. 버그를 고치고 Qwen3 단일 모델로 정리한 형태. 함수/클래스로 감쌀 때 이 패턴을 따른다.

## 1. 오디오 로딩 + 청킹 (audio.py)

```python
import librosa
import soundfile as sf  # 반드시 상단에서 import (NameError 방지)

def load_audio(path, sr=None):
    audio, sample_rate = librosa.load(path, sr=sr, mono=True)
    return audio, sample_rate

def chunk_audio(audio, sample_rate, chunk_sec=30, overlap_sec=2):
    step_sec = chunk_sec - overlap_sec
    chunk_samples = int(chunk_sec * sample_rate)
    step_samples = int(step_sec * sample_rate)
    chunks = []
    start = 0
    while start < len(audio):
        end = min(start + chunk_samples, len(audio))
        chunks.append({
            "audio": audio[start:end],
            "start_sec": start / sample_rate,
            "end_sec": end / sample_rate,
        })
        start += step_samples
    return chunks

def write_wav(path, audio, sample_rate):
    sf.write(path, audio, sample_rate)  # sf가 상단에서 import되어 안전
```

## 2. Qwen3-ASR 래퍼 (asr.py)

```python
from pathlib import Path
from qwen_asr import Qwen3ASRModel

class Qwen3Engine:
    def __init__(self, model_path, device, dtype):
        p = Path(model_path)
        if not p.exists():
            raise FileNotFoundError(
                f"{model_path} 가 없습니다. setup.ipynb Step 7로 모델을 받으세요.")
        self.model = Qwen3ASRModel.from_pretrained(
            str(p), dtype=dtype, device_map=device,
            max_inference_batch_size=8, max_new_tokens=512,
        )

    def transcribe_file(self, wav_path, context=None):
        kwargs = {"language": "Korean"}
        if context:
            kwargs["context"] = context  # 쉼표 구분 키워드만 (qwen-asr 0.0.6 실제 인자명)
        result = self.model.transcribe(audio=wav_path, **kwargs)
        return result[0].text.strip()
```

청크 단위 전사는 각 청크를 임시 wav로 쓰고 `transcribe_file`을 호출한 뒤 텍스트를 이어붙인다. `tempfile.TemporaryDirectory()`를 사용한다.

### context biasing 규칙
- **실제 API(qwen-asr 0.0.6):** `transcribe(audio, context="", language=None, return_time_stamps=False)`. 결과는 `List[ASRTranscription]`, 텍스트는 `result[0].text`. 노트북의 `initial_prompt` 인자는 실제 패키지에 없으므로 쓰지 않는다.
- `context`는 **쉼표로 구분된 키워드** 문자열. 예: `"LLM-Wiki, Obsidian, Qwen3-ASR, 화자분리, 김상규, 박성준"`.
- 해당 회의에서 실제 쓰는 용어만 소수 선별. 무관한 단어(distractor)는 인식을 방해한다.
- context 없는 결과와 비교 가능하도록 `context=None`도 항상 지원한다.

## 3. pyannote 화자분리 (diarize.py)

> **실측 반영 (pyannote.audio 4.0.4):**
> - 공식 `pyannote/speaker-diarization-3.1`·`community-1`은 **gated**(약관 수동 동의 필요). API로 동의는 불가(웹 전용). pyannote는 MIT 라이선스라 **비-gated 미러** `pyannote-community/speaker-diarization-community-1`(segmentation+embedding+plda 자체 포함)을 쓰면 동의 없이 동작한다. → `config.DIARIZE_SOURCE`.
> - `Pipeline.from_pretrained(...)` 인자는 `token=`(구버전 `use_auth_token=` 아님).
> - 호출 결과는 `DiarizeOutput`이며 `.speaker_diarization`(Annotation)에 `itertracks`가 있다. 3.x는 Annotation을 직접 반환 → `getattr(result, "speaker_diarization", result)`로 양쪽 호환.
> - `min_duration_off` 속성이 없을 수 있어 try/except로 설정.
> - 화자분리는 충분한 길이(수십 초)가 필요 — 너무 짧으면 "too short to contain 2+ speakers".

```python
import json, torch
from pathlib import Path
from huggingface_hub import login
from pyannote.audio import Pipeline

class Diarizer:
    def __init__(self, diarize_path, hf_token, device):
        login(token=hf_token, add_to_git_credential=False)
        self.pipeline = Pipeline.from_pretrained(str(diarize_path))
        self.pipeline.segmentation.min_duration_off = 1.0  # 검증된 값
        self.pipeline = self.pipeline.to(torch.device(device))

    def run(self, audio, sample_rate, num_speakers=None):
        waveform = torch.tensor(audio).unsqueeze(0).float()
        params = {"waveform": waveform, "sample_rate": sample_rate}
        kwargs = {"num_speakers": num_speakers} if num_speakers else {}
        result = self.pipeline(params, **kwargs)
        segments = []
        for turn, _, speaker in result.itertracks(yield_label=True):
            segments.append({"speaker": speaker, "start": turn.start, "end": turn.end})
        return segments
```

- HF 토큰(`.env`의 `HF_TOKEN` 또는 환경변수)으로 로그인 — `config.load_hf_token()` 사용. 비-gated 미러를 쓰면 약관 동의 불필요.
- 화자 수를 알면 `num_speakers=N`을 넘기면 정확도가 오른다(강의자료 권장).
- `SPEAKER_00/01`은 익명 라벨 — 실제 이름 매핑은 회의록 단계에서.

## 4. 화자별 전사 (pipeline에서 사용)

각 세그먼트 구간 오디오를 잘라 임시 wav로 쓰고 Qwen3로 전사한다. 빈 구간은 건너뛴다.

```python
chunk = audio[int(seg["start"]*sr):int(seg["end"]*sr)]
if len(chunk) == 0:
    continue
write_wav(tmp_path, chunk, sr)
text = engine.transcribe_file(tmp_path, context=context)
```
