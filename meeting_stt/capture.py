"""오프라인 오디오 캡처. 백엔드(sounddevice)가 녹음하므로 마이크와 시스템/앱 오디오를
동일하게 입력 장치로 선택할 수 있다.

모든 레코더는 공통 하트비트 인터페이스를 노출한다:
- `is_recording: bool`
- `level: float`  — 최근 RMS(약 0..1). 무신호 시 0(감쇠).

import-safe: sounddevice/numpy는 함수·메서드 내부에서 지연 import한다.
`import meeting_stt.capture`만으로 PortAudio를 열거나 장치를 점유하지 않는다."""

from __future__ import annotations

import time
from pathlib import Path
from typing import List, Optional

from .audio import write_wav

# 네이티브 앱별 캡처 헬퍼(Swift) 경로: <project_root>/native/apptap
APPTAP = Path(__file__).resolve().parent.parent / "native" / "apptap"

# level 프로퍼티 감쇠 윈도우: 마지막 갱신이 이보다 오래되면 0.0 반환
_LEVEL_STALE_SEC = 0.5

# 네이티브 헬퍼 미존재 시 안내 메시지(빌드 방법)
_APPTAP_MISSING = (
    "App/system capture helper (native/apptap) is missing. Build it with: "
    "swiftc -O native/apptap.swift -o native/apptap "
    "-framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit"
)


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
        self._level: float = 0.0
        self._level_ts: float = 0.0
        self._nframes: int = 0

    @property
    def is_recording(self) -> bool:
        return self._stream is not None

    @property
    def level(self) -> float:
        """최근 블록 RMS(약 0..1). 마지막 갱신이 0.5초 넘게 오래되면 0.0(감쇠)."""
        if time.time() - self._level_ts > _LEVEL_STALE_SEC:
            return 0.0
        return self._level

    @property
    def buffered_bytes(self) -> int:
        """지금까지 누적 프레임을 int16(2바이트)로 가정한 근사 바이트 수(status용)."""
        return self._nframes * 2 * self.channels

    def _resolve_samplerate(self) -> int:
        if self.samplerate:
            return int(self.samplerate)
        import sounddevice as sd

        info = sd.query_devices(self.device, "input") if self.device is not None else sd.query_devices(kind="input")
        return int(info.get("default_samplerate", 16000))

    def start(self) -> None:
        if self._stream is not None:
            raise RuntimeError("A recording is already in progress.")
        import numpy as np
        import sounddevice as sd

        self.samplerate = self._resolve_samplerate()
        self._frames = []
        self._level = 0.0
        self._level_ts = 0.0
        self._nframes = 0

        def callback(indata, frames, time_info, status):
            self._frames.append(indata.copy())
            self._nframes += frames
            # 블록 RMS로 하트비트 레벨 갱신
            self._level = float(np.sqrt(np.mean(indata ** 2)))
            self._level_ts = time.time()

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
                f"Could not start recording (device={self.device}, {self.samplerate}Hz, "
                f"{self.channels}ch): {e}"
            ) from e

    def stop(self, out_path: str) -> str:
        if self._stream is None:
            raise RuntimeError("Recording has not started.")
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
# 네이티브 캡처 (macOS, Core Audio Process Tap — native/apptap)
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


class _NativeRecorder:
    """native/apptap 서브프로세스 기반 레코더의 공통 베이스.

    apptap은 녹음 중 stdout으로 약 200ms마다 `LEVEL <float>` 라인을 출력한다.
    이를 데몬 스레드로 읽어 하트비트 레벨을 갱신한다. wav finalize는 SIGTERM으로 트리거한다.
    하위 클래스는 `start(out_path)`에서 `self._spawn(argv, out_path)`를 호출한다."""

    def __init__(self):
        self._proc = None
        self._out: Optional[str] = None
        self._level: float = 0.0
        self._level_ts: float = 0.0
        self._reader = None

    @property
    def is_recording(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    @property
    def level(self) -> float:
        """apptap이 보고한 최근 RMS. 0.5초 넘게 갱신 없으면 0.0(감쇠)."""
        if time.time() - self._level_ts > _LEVEL_STALE_SEC:
            return 0.0
        return self._level

    def _spawn(self, argv: list, out_path: str) -> None:
        import subprocess

        if not APPTAP.exists():
            raise RuntimeError(_APPTAP_MISSING)
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        self._out = out_path
        self._level = 0.0
        self._level_ts = 0.0
        self._proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # 시작 직후 즉사하면(권한 거부 등) stderr를 읽어 에러로 전달
        time.sleep(0.4)
        if self._proc.poll() is not None:
            err = self._proc.stderr.read().decode("utf-8", "ignore") if self._proc.stderr else ""
            self._proc = None
            raise RuntimeError(f"Could not start recording: {err.strip() or 'apptap exited immediately'}")
        # 즉사 체크 통과 후에야 stdout 리더 시작(즉사 체크는 stderr만 사용)
        self._start_reader()

    def _start_reader(self) -> None:
        import threading

        proc = self._proc

        def _read():
            stdout = proc.stdout
            if stdout is None:
                return
            for raw in iter(stdout.readline, b""):
                line = raw.decode("utf-8", "ignore").strip()
                if line.startswith("LEVEL "):
                    try:
                        self._level = float(line[6:].strip())
                        self._level_ts = time.time()
                    except ValueError:
                        pass
                # 그 외 라인은 무시. EOF면 readline이 b""를 반환 → 루프 종료.

        self._reader = threading.Thread(target=_read, daemon=True)
        self._reader.start()

    def stop(self) -> str:
        if self._proc is None:
            raise RuntimeError("Recording has not started.")
        self._proc.terminate()  # SIGTERM → apptap이 wav를 finalize
        try:
            self._proc.wait(timeout=5)
        except Exception:
            self._proc.kill()
        self._proc = None
        return self._out or ""


class AppRecorder(_NativeRecorder):
    """native/apptap로 특정 앱(pid)의 오디오를 녹음."""

    def __init__(self, pid: int):
        super().__init__()
        self.pid = pid

    def start(self, out_path: str) -> None:
        self._spawn([str(APPTAP), "record", "--pid", str(self.pid), "--out", out_path], out_path)


class SystemRecorder(_NativeRecorder):
    """native/apptap로 시스템 전체 출력(스피커로 나가는 모든 소리)을 녹음. 앱 선택 불필요."""

    def start(self, out_path: str) -> None:
        self._spawn([str(APPTAP), "record-system", "--out", out_path], out_path)
