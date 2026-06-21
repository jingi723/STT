"""로컬 웹 대시보드 백엔드. 녹음(capture)·전사(pipeline)·회의록(notes)을 한 화면에서.

import-safe: fastapi/uvicorn은 create_app()/run_server() 내부에서 지연 import한다.
`import meeting_stt.server`와 `python -m py_compile`은 fastapi 미설치 환경에서도 통과한다.

주의: 여기서는 `from __future__ import annotations`를 쓰지 않는다. create_app() 안에 정의한
지역 Pydantic 모델(StartBody 등)을 FastAPI가 본문 모델로 인식하려면 애노테이션이 문자열이
아니라 실제 클래스 객체여야 하기 때문이다(문자열이면 모듈 전역에서 못 찾아 422가 난다)."""

import json
import time
from pathlib import Path

from .capture import AppRecorder, Recorder, list_app_sources, list_input_devices
from .config import Config

WEB_DIR = Path(__file__).parent / "web"


class _State:
    """서버 프로세스가 보유하는 단일 녹음 세션 상태(장치 또는 앱)."""

    recorder: object | None = None   # Recorder(device) | AppRecorder(app)
    kind: str | None = None          # "device" | "app"
    out_path: str | None = None      # 앱 녹음은 시작 시점에 경로 확정
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
        source: str = "device"        # "device"(마이크/sounddevice) | "app"(앱별 캡처)
        device: int | None = None     # source=device 일 때
        pid: int | None = None        # source=app 일 때

    class TranscribeBody(BaseModel):
        path: str
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
        rec_dir = config.outputs_dir / "recordings"
        rec_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d_%H%M%S")
        out_path = str(rec_dir / f"{stamp}.wav")
        try:
            if body.source == "app":
                if body.pid is None:
                    raise HTTPException(400, "앱 녹음에는 pid가 필요합니다.")
                rec = AppRecorder(pid=body.pid)
                rec.start(out_path)  # 앱 캡처는 시작 시점에 파일에 기록
            else:
                rec = Recorder(device=body.device)
                rec.start()
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(400, str(e))
        state.recorder = rec
        state.kind = body.source
        state.out_path = out_path
        state.started_at = time.time()
        return {"status": "recording", "source": body.source}

    @app.post("/api/record/stop")
    def record_stop():
        if state.recorder is None or not getattr(state.recorder, "is_recording", False):
            raise HTTPException(400, "녹음이 시작되지 않았습니다.")
        try:
            if state.kind == "app":
                out_path = state.recorder.stop()
            else:
                out_path = state.out_path
                state.recorder.stop(out_path)
        except Exception as e:
            raise HTTPException(500, f"녹음 저장 실패: {e}")
        duration = time.time() - (state.started_at or time.time())
        state.recorder = None
        state.kind = None
        state.out_path = None
        state.started_at = None
        return {"status": "stopped", "path": out_path, "duration_sec": round(duration, 1)}

    @app.post("/api/transcribe")
    def transcribe(body: TranscribeBody):
        from .pipeline import transcribe as run_transcribe

        if not Path(body.path).exists():
            raise HTTPException(404, f"오디오 파일 없음: {body.path}")
        try:
            data = run_transcribe(
                audio_path=body.path, context=body.context, num_speakers=body.num_speakers,
                diarize=body.diarize, project=body.project, date=body.date, config=config,
            )
        except Exception as e:
            raise HTTPException(500, f"전사 실패: {e}")
        return JSONResponse(data)

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
