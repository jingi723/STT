"""오프라인 오디오 캡처. 백엔드(sounddevice)가 녹음하므로 마이크와 시스템/앱 오디오를
동일하게 입력 장치로 선택할 수 있다.

import-safe: sounddevice/numpy는 함수·메서드 내부에서 지연 import한다.
`import meeting_stt.capture`만으로 PortAudio를 열거나 장치를 점유하지 않는다."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from .audio import write_wav

# 네이티브 앱별 캡처 헬퍼(Swift) 경로: <project_root>/native/apptap
APPTAP = Path(__file__).resolve().parent.parent / "native" / "apptap"


def list_input_devices() -> List[dict]:
    """입력 채널이 있는 장치 목록. macOS 시스템 오디오는 BlackHole 설치 시 여기에 나타난다."""
    import sounddevice as sd

    devices = []
    for index, d in enumerate(sd.query_devices()):
        if d.get("max_input_channels", 0) > 0:
            devices.append(
                {
                    "index": index,
                    "name": d.get("name", f"device {index}"),
                    "channels": d.get("max_input_channels", 0),
                    "default_samplerate": int(d.get("default_samplerate", 0)),
                }
            )
    return devices


class Recorder:
    """선택 장치에서 start/stop 방식으로 녹음. 콜백으로 프레임을 누적해 메인 스레드를 막지 않는다."""

    def __init__(self, device: Optional[int] = None, samplerate: Optional[int] = None, channels: int = 1):
        self.device = device
        self.samplerate = samplerate
        self.channels = channels
        self._stream = None
        self._frames: list = []

    @property
    def is_recording(self) -> bool:
        return self._stream is not None

    def _resolve_samplerate(self) -> int:
        if self.samplerate:
            return int(self.samplerate)
        import sounddevice as sd

        info = sd.query_devices(self.device, "input") if self.device is not None else sd.query_devices(kind="input")
        return int(info.get("default_samplerate", 16000))

    def start(self) -> None:
        if self._stream is not None:
            raise RuntimeError("이미 녹음 중입니다.")
        import sounddevice as sd

        self.samplerate = self._resolve_samplerate()
        self._frames = []

        def callback(indata, frames, time_info, status):
            self._frames.append(indata.copy())

        try:
            self._stream = sd.InputStream(
                device=self.device,
                samplerate=self.samplerate,
                channels=self.channels,
                callback=callback,
            )
            self._stream.start()
        except Exception as e:  # PortAudioError 등
            self._stream = None
            raise RuntimeError(
                f"녹음을 시작할 수 없습니다(device={self.device}, {self.samplerate}Hz, "
                f"{self.channels}ch): {e}"
            ) from e

    def stop(self, out_path: str) -> str:
        if self._stream is None:
            raise RuntimeError("녹음이 시작되지 않았습니다.")
        import numpy as np

        self._stream.stop()
        self._stream.close()
        self._stream = None

        if self._frames:
            data = np.concatenate(self._frames, axis=0)
        else:
            data = np.zeros((0, self.channels), dtype="float32")
        # 모노로 저장(다채널이면 평균)
        if data.ndim == 2 and data.shape[1] > 1:
            data = data.mean(axis=1)
        write_wav(out_path, data, self.samplerate)
        self._frames = []
        return out_path


# ─────────────────────────────────────────────────────────────
# 앱별 오디오 캡처 (macOS, Core Audio Process Tap — native/apptap)
# ─────────────────────────────────────────────────────────────

def list_app_sources() -> List[dict]:
    """소리를 내는 앱(프로세스) 목록. [{"pid","name","bundleID"}]. 헬퍼 없으면 빈 목록."""
    import json
    import subprocess

    if not APPTAP.exists():
        return []
    try:
        out = subprocess.run([str(APPTAP), "list"], capture_output=True, text=True, timeout=10)
        if out.returncode != 0:
            return []
        return json.loads(out.stdout or "[]")
    except Exception:
        return []


class AppRecorder:
    """native/apptap 서브프로세스로 특정 앱의 오디오를 녹음. start에서 시작, stop에서 SIGTERM."""

    def __init__(self, pid: int):
        self.pid = pid
        self._proc = None
        self._out: Optional[str] = None

    @property
    def is_recording(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def start(self, out_path: str) -> None:
        import subprocess
        import time

        if not APPTAP.exists():
            raise RuntimeError(
                "앱별 캡처 헬퍼(native/apptap)가 없습니다. 빌드: "
                "swiftc -O native/apptap.swift -o native/apptap "
                "-framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit"
            )
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        self._out = out_path
        self._proc = subprocess.Popen(
            [str(APPTAP), "record", "--pid", str(self.pid), "--out", out_path],
            stderr=subprocess.PIPE,
        )
        # 시작 직후 즉사하면(권한 거부 등) 에러로 전달
        time.sleep(0.4)
        if self._proc.poll() is not None:
            err = self._proc.stderr.read().decode("utf-8", "ignore") if self._proc.stderr else ""
            self._proc = None
            raise RuntimeError(f"앱 녹음 시작 실패: {err.strip() or 'apptap 즉시 종료'}")

    def stop(self) -> str:
        if self._proc is None:
            raise RuntimeError("녹음이 시작되지 않았습니다.")
        self._proc.terminate()  # SIGTERM → apptap이 wav를 finalize
        try:
            self._proc.wait(timeout=5)
        except Exception:
            self._proc.kill()
        self._proc = None
        return self._out or ""
