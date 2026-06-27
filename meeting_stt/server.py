"""로컬 웹 대시보드 백엔드. 녹음(capture)·전사(pipeline)·회의록(notes)을 한 화면에서.

import-safe: fastapi/uvicorn은 create_app()/run_server() 내부에서 지연 import한다.
`import meeting_stt.server`와 `python -m py_compile`은 fastapi 미설치 환경에서도 통과한다.

주의: 여기서는 `from __future__ import annotations`를 쓰지 않는다. create_app() 안에 정의한
지역 Pydantic 모델(StartBody 등)을 FastAPI가 본문 모델로 인식하려면 애노테이션이 문자열이
아니라 실제 클래스 객체여야 하기 때문이다(문자열이면 모듈 전역에서 못 찾아 422가 난다)."""

import json
import time
from pathlib import Path

from .capture import AppRecorder, Recorder, SystemRecorder, list_app_sources, list_input_devices
from .config import Config

WEB_DIR = Path(__file__).parent / "web"


class _State:
    """서버 프로세스가 보유하는 단일 녹음 세션 상태(장치 또는 앱)."""

    recorder: object | None = None   # Recorder(device) | AppRecorder(app) | SystemRecorder(system)
    kind: str | None = None          # "device" | "app" | "system"
    out_path: str | None = None      # 현재 세션의 audio.wav 경로
    session_id: str | None = None
    session_dir: Path | None = None
    started_at: float | None = None


def create_app():
    """FastAPI 앱 생성. fastapi는 여기서 지연 import."""
    from fastapi import FastAPI, HTTPException
    from fastapi.responses import FileResponse, JSONResponse
    from pydantic import BaseModel

    app = FastAPI(title="meeting_stt dashboard")
    config = Config.from_cwd()
    state = _State()

    class StartBody(BaseModel):
        source: str = "device"        # "device"(마이크/sounddevice) | "app"(앱별 캡처) | "system"(시스템 전체 출력)
        device: int | None = None     # source=device 일 때
        pid: int | None = None        # source=app 일 때

    class TranscribeBody(BaseModel):
        path: str | None = None
        audio_path: str | None = None
        session_id: str | None = None
        context: str | None = None
        num_speakers: int | None = None
        diarize: bool = True
        project: str | None = None
        date: str | None = None

    class RecordingTranscribeBody(BaseModel):
        context: str | None = None
        num_speakers: int | None = None
        diarize: bool = True
        project: str | None = None
        date: str | None = None

    class NotesBody(BaseModel):
        transcript_json: str
        project: str | None = None
        prompt_only: bool = False
        wiki: str | None = None

    def _recordings_dir() -> Path:
        path = config.outputs_dir / "recordings"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _session_dir(session_id: str) -> Path:
        if not session_id or "/" in session_id or "\\" in session_id or session_id in (".", ".."):
            raise HTTPException(400, "잘못된 녹음 세션입니다.")
        path = (_recordings_dir() / session_id).resolve()
        root = _recordings_dir().resolve()
        if path.parent != root:
            raise HTTPException(400, "잘못된 녹음 세션 경로입니다.")
        return path

    def _new_session() -> tuple[str, Path]:
        base = time.strftime("%Y%m%d_%H%M%S")
        session_id = base
        suffix = 2
        while _session_dir(session_id).exists():
            session_id = f"{base}_{suffix}"
            suffix += 1
        return session_id, _session_dir(session_id)

    def _metadata_path(session_dir: Path) -> Path:
        return session_dir / "metadata.json"

    def _read_metadata(session_dir: Path) -> dict:
        path = _metadata_path(session_dir)
        if not path.exists():
            return {}
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def _write_metadata(session_dir: Path, data: dict) -> None:
        session_dir.mkdir(parents=True, exist_ok=True)
        _metadata_path(session_dir).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def _recording_payload(session_dir: Path) -> dict:
        session_id = session_dir.name
        audio_path = session_dir / "audio.wav"
        audio_exists = audio_path.exists()
        meta = _read_metadata(session_dir)
        transcript_json_value = meta.get("transcript_json")
        transcript_md_value = meta.get("transcript_md")
        transcript_json = Path(transcript_json_value) if transcript_json_value else config.outputs_dir / f"{session_id}.json"
        transcript_md = Path(transcript_md_value) if transcript_md_value else config.outputs_dir / f"{session_id}.md"
        transcribed = bool(meta.get("transcribed")) or transcript_json.exists()
        created_at = meta.get("created_at") or meta.get("started_at")
        return {
            "session_id": session_id,
            "id": session_id,
            "session_dir": str(session_dir),
            "audio_path": str(audio_path) if audio_exists else None,
            "path": str(audio_path) if audio_exists else None,
            "audio_url": f"/api/recordings/{session_id}/audio" if audio_exists else None,
            "status": meta.get("status") or ("recorded" if audio_exists else "empty"),
            "source": meta.get("source"),
            "device": meta.get("device"),
            "pid": meta.get("pid"),
            "created_at": created_at,
            "started_at": meta.get("started_at"),
            "stopped_at": meta.get("stopped_at"),
            "duration_sec": meta.get("duration_sec"),
            "bytes": audio_path.stat().st_size if audio_exists else 0,
            "transcribed": transcribed,
            "transcript_json": str(transcript_json) if transcript_json.exists() else None,
            "transcript_md": str(transcript_md) if transcript_md.exists() else None,
        }

    def _update_session_metadata(status: str, **fields) -> None:
        if state.session_dir is None:
            return
        meta = _read_metadata(state.session_dir)
        meta.update(fields)
        meta["status"] = status
        _write_metadata(state.session_dir, meta)

    @app.get("/")
    def index():
        return FileResponse(str(WEB_DIR / "index.html"))

    @app.get("/api/devices")
    def devices():
        try:
            return {"devices": list_input_devices()}
        except Exception as e:
            raise HTTPException(500, f"장치 목록 조회 실패(sounddevice/PortAudio 설치 확인): {e}")

    @app.get("/api/app-sources")
    def app_sources():
        """소리 내는 앱 목록(앱별 캡처용). 헬퍼 없으면 빈 목록 + available=false."""
        sources = list_app_sources()
        from .capture import APPTAP

        return {"available": APPTAP.exists(), "sources": sources}

    @app.post("/api/record/start")
    def record_start(body: StartBody):
        if state.recorder is not None and getattr(state.recorder, "is_recording", False):
            raise HTTPException(409, "이미 녹음 중입니다.")
        if body.source not in {"device", "app", "system"}:
            raise HTTPException(400, "source는 device, app, system 중 하나여야 합니다.")
        stamp, session_dir = _new_session()
        out_path = str(session_dir / "audio.wav")
        started_at = time.time()
        meta = {
            "session_id": stamp,
            "session_dir": str(session_dir),
            "status": "recording",
            "source": body.source,
            "device": body.device,
            "pid": body.pid,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(started_at)),
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(started_at)),
            "started_at_epoch": started_at,
            "audio_path": out_path,
            "audio_url": f"/api/recordings/{stamp}/audio",
        }
        _write_metadata(session_dir, meta)
        try:
            if body.source == "app":
                if body.pid is None:
                    raise HTTPException(400, "앱 녹음에는 pid가 필요합니다.")
                rec = AppRecorder(pid=body.pid)
                rec.start(out_path)  # 앱 캡처는 시작 시점에 파일에 기록
            elif body.source == "system":
                rec = SystemRecorder()
                rec.start(out_path)  # 시스템 전체 출력 캡처(시작 시점에 파일에 기록)
            else:
                rec = Recorder(device=body.device)
                rec.start()
        except HTTPException:
            _write_metadata(session_dir, {**meta, "status": "error"})
            raise
        except Exception as e:
            _write_metadata(session_dir, {**meta, "status": "error", "error": str(e)})
            raise HTTPException(400, str(e))
        state.recorder = rec
        state.kind = body.source
        state.out_path = out_path
        state.session_id = stamp
        state.session_dir = session_dir
        state.started_at = started_at
        return {
            "status": "recording",
            "source": body.source,
            "session_id": stamp,
            "id": stamp,
            "session_dir": str(session_dir),
            "audio_path": out_path,
            "path": out_path,
            "audio_url": f"/api/recordings/{stamp}/audio",
        }

    @app.post("/api/record/stop")
    def record_stop():
        if state.recorder is None or not getattr(state.recorder, "is_recording", False):
            raise HTTPException(400, "녹음이 시작되지 않았습니다.")
        try:
            if state.kind in ("app", "system"):
                out_path = state.recorder.stop()  # 네이티브가 wav finalize(인자 없음)
            else:
                out_path = state.out_path
                state.recorder.stop(out_path)
        except Exception as e:
            _update_session_metadata("error", error=f"녹음 저장 실패: {e}", stopped_at=time.strftime("%Y-%m-%dT%H:%M:%S%z"))
            raise HTTPException(500, f"녹음 저장 실패: {e}")
        duration = time.time() - (state.started_at or time.time())
        session_id = state.session_id
        session_dir = state.session_dir
        audio_path = Path(out_path or "")
        _update_session_metadata(
            "recorded",
            stopped_at=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            duration_sec=round(duration, 1),
            audio_path=str(audio_path),
            audio_url=f"/api/recordings/{session_id}/audio" if session_id else None,
            bytes=audio_path.stat().st_size if audio_path.exists() else 0,
        )
        state.recorder = None
        state.kind = None
        state.out_path = None
        state.session_id = None
        state.session_dir = None
        state.started_at = None
        return {
            "status": "stopped",
            "path": str(audio_path),
            "audio_path": str(audio_path),
            "audio_url": f"/api/recordings/{session_id}/audio" if session_id else None,
            "session_id": session_id,
            "id": session_id,
            "session_dir": str(session_dir) if session_dir else None,
            "duration_sec": round(duration, 1),
        }

    @app.get("/api/record/status")
    def record_status():
        """하트비트 폴링용. 절대 예외를 던지지 않고 항상 200 JSON을 반환한다."""
        try:
            recorder = state.recorder
            recording = recorder is not None and getattr(recorder, "is_recording", False)
            level = float(getattr(recorder, "level", 0.0) or 0.0) if recording else 0.0
            if recording and state.kind in ("app", "system"):
                try:
                    nbytes = Path(state.out_path).stat().st_size
                except Exception:
                    nbytes = 0
            elif recording:
                nbytes = int(getattr(recorder, "buffered_bytes", 0) or 0)
            else:
                nbytes = 0
            elapsed = (time.time() - state.started_at) if (recording and state.started_at) else 0.0
            return {
                "recording": recording,
                "source": state.kind if recording else None,
                "session_id": state.session_id if recording else None,
                "id": state.session_id if recording else None,
                "session_dir": str(state.session_dir) if recording and state.session_dir else None,
                "audio_path": state.out_path if recording else None,
                "audio_url": f"/api/recordings/{state.session_id}/audio" if recording and state.session_id else None,
                "elapsed_sec": round(elapsed, 1),
                "level": round(level, 4),
                "bytes": nbytes,
            }
        except Exception:
            return {"recording": False, "source": None, "elapsed_sec": 0.0, "level": 0.0, "bytes": 0}

    @app.get("/api/recordings")
    def recordings():
        root = _recordings_dir()
        items = [_recording_payload(p) for p in sorted(root.iterdir(), reverse=True) if p.is_dir()]
        return {"recordings": items}

    @app.get("/api/recordings/{session_id}/audio")
    def recording_audio(session_id: str):
        session_dir = _session_dir(session_id)
        audio_path = session_dir / "audio.wav"
        if not audio_path.exists():
            raise HTTPException(404, "녹음 파일이 없습니다.")
        return FileResponse(str(audio_path), media_type="audio/wav", filename=f"{session_id}.wav")

    def _run_transcribe(audio_path: str, body) -> dict:
        from .pipeline import transcribe as run_transcribe

        audio = Path(audio_path)
        if not audio.exists():
            raise HTTPException(404, f"오디오 파일 없음: {audio_path}")
        try:
            data = run_transcribe(
                audio_path=str(audio), context=body.context, num_speakers=body.num_speakers,
                diarize=body.diarize, project=body.project, date=body.date, config=config,
            )
        except Exception as e:
            raise HTTPException(500, f"전사 실패: {e}")
        try:
            session_dir = audio.resolve().parent
            is_session_audio = audio.resolve().name == "audio.wav" and session_dir.parent == _recordings_dir().resolve()
        except Exception:
            session_dir = audio.parent
            is_session_audio = False
        if is_session_audio:
            meta = _read_metadata(session_dir)
            meta.update({
                "status": "transcribed",
                "transcribed": True,
                "transcribed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "transcript_json": data.get("_json_path"),
                "transcript_md": data.get("_md_path"),
            })
            _write_metadata(session_dir, meta)
            data["_session_id"] = session_dir.name
            data["_audio_url"] = f"/api/recordings/{session_dir.name}/audio"
        return data

    @app.post("/api/recordings/{session_id}/transcribe")
    def transcribe_recording(session_id: str, body: RecordingTranscribeBody):
        if state.session_id == session_id and state.recorder is not None and getattr(state.recorder, "is_recording", False):
            raise HTTPException(409, "녹음 중인 세션은 정지 후 전사하세요.")
        session_dir = _session_dir(session_id)
        audio_path = session_dir / "audio.wav"
        return JSONResponse(_run_transcribe(str(audio_path), body))

    @app.post("/api/transcribe")
    def transcribe(body: TranscribeBody):
        if body.session_id:
            if state.session_id == body.session_id and state.recorder is not None and getattr(state.recorder, "is_recording", False):
                raise HTTPException(409, "녹음 중인 세션은 정지 후 전사하세요.")
            audio_path = _session_dir(body.session_id) / "audio.wav"
        else:
            requested = body.audio_path or body.path
            if not requested:
                raise HTTPException(400, "path 또는 session_id가 필요합니다.")
            audio_path = Path(requested)
        return JSONResponse(_run_transcribe(str(audio_path), body))

    @app.post("/api/notes")
    def notes(body: NotesBody):
        from .notes import generate_local_notes, generate_prompt
        from .wiki import read_context

        jpath = Path(body.transcript_json)
        if not jpath.exists():
            raise HTTPException(404, f"transcript json 없음: {jpath}")
        data = json.loads(jpath.read_text(encoding="utf-8"))
        project = body.project or data.get("project") or "My-app"
        if body.prompt_only:
            out = generate_prompt(data, project=project)
            out_path = jpath.with_suffix(".prompt.md")
        else:
            ctx = read_context(body.wiki, project=project) if body.wiki else None
            out = generate_local_notes(data, ctx)
            out_path = jpath.with_suffix(".md")  # 전사 .md에 회의록(전사 포함)으로 통합 → 회의당 한 파일
        out_path.write_text(out, encoding="utf-8")
        return {"path": str(out_path), "content": out}

    @app.get("/api/results")
    def results():
        out = config.outputs_dir
        if not out.exists():
            return {"results": []}
        items = []
        for f in sorted(out.glob("*.md")):
            items.append({"name": f.name, "path": str(f)})
        return {"results": items}

    return app


def run_server(host: str = "127.0.0.1", port: int = 8000) -> None:
    """uvicorn으로 대시보드 구동. uvicorn은 여기서 지연 import."""
    import uvicorn

    print(f"대시보드: http://{host}:{port}  (Ctrl+C로 종료)")
    uvicorn.run(create_app(), host=host, port=port)
