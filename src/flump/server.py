"""Local API. Bound to this machine and closed to other websites."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from urllib.parse import urlparse

from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse

from flump.jobs import JobManager
from flump.platform import open_path, pick_folder, reveal_path

STATIC = Path(__file__).resolve().parent / "static"
_ASSETS = {
    "app.js": "text/javascript; charset=utf-8",
    "styles.css": "text/css; charset=utf-8",
    "favicon.svg": "image/svg+xml",
}
_LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}


def create_app(manager: JobManager) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        manager.start()
        yield
        manager.stop()

    app = FastAPI(title="Flump", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.manager = manager

    @app.middleware("http")
    async def same_machine(request: Request, call_next):
        origin = request.headers.get("origin")
        if origin:
            host = (urlparse(origin).hostname or "").lower()
            if host not in _LOCAL_HOSTS:
                return JSONResponse({"error": "Flump only runs on this computer."}, status_code=403)
        return await call_next(request)

    @app.get("/")
    def index():
        return FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-store"})

    @app.get("/static/{name}")
    def asset(name: str):
        media = _ASSETS.get(name)
        if media is None:
            raise HTTPException(404)
        return FileResponse(STATIC / name, media_type=media, headers={"Cache-Control": "no-store"})

    @app.get("/api/state")
    def state():
        return manager.state()

    @app.post("/api/submit")
    def submit(payload: dict):
        text = payload.get("text") if isinstance(payload, dict) else None
        if not isinstance(text, str) or len(text) > 20_000:
            raise HTTPException(400, "No link found.")
        try:
            ids = manager.submit_text(text)
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        return {"ids": ids, **manager.state()}

    @app.put("/api/settings")
    def update_settings(payload: dict):
        if not isinstance(payload, dict):
            raise HTTPException(400, "Couldn't read settings.")
        try:
            manager.settings.update(payload)
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        return manager.state()

    @app.post("/api/settings/pick-folder")
    def choose_folder():
        if sys.platform != "darwin":
            raise HTTPException(400, "Type the folder path on this system.")
        chosen = pick_folder()
        if not chosen:
            raise HTTPException(400, "Folder selection was cancelled.")
        try:
            manager.settings.update({"download_dir": chosen})
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        return manager.state()

    @app.post("/api/settings/open-folder")
    def open_folder():
        settings, _ = manager.settings.snapshot()
        open_path(settings.download_dir)
        return {"ok": True}

    @app.post("/api/jobs/{job_id}/cancel")
    def cancel(job_id: str):
        _missing(lambda: manager.cancel(job_id))
        return manager.state()

    @app.post("/api/jobs/{job_id}/dismiss")
    def dismiss(job_id: str):
        try:
            manager.dismiss(job_id)
        except KeyError:
            raise HTTPException(404, "Item not found.") from None
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        return manager.state()

    @app.post("/api/jobs/{job_id}/retry")
    def retry(job_id: str):
        try:
            manager.retry(job_id)
        except KeyError:
            raise HTTPException(404, "Item not found.") from None
        return manager.state()

    @app.post("/api/jobs/{job_id}/entries")
    def entries(job_id: str, payload: dict):
        indexes = None
        if isinstance(payload, dict) and payload.get("indexes") is not None:
            raw = payload.get("indexes")
            if not isinstance(raw, list) or not all(isinstance(item, int) for item in raw):
                raise HTTPException(400, "Choose a video to save.")
            indexes = raw
        try:
            manager.download_entries(job_id, indexes)
        except KeyError:
            raise HTTPException(404, "Playlist not found.") from None
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        return manager.state()

    @app.post("/api/jobs/{job_id}/reveal")
    def reveal(job_id: str):
        path = _file(job_id)
        reveal_path(path)
        return {"ok": True}

    @app.post("/api/jobs/{job_id}/open")
    def open_file(job_id: str):
        path = _file(job_id)
        open_path(path)
        return {"ok": True}

    @app.delete("/api/history/{item_id}")
    def drop_history(item_id: str):
        if not manager.settings.drop_history(item_id):
            raise HTTPException(404, "Item not found.")
        return manager.state()

    @app.delete("/api/history")
    def clear_history():
        manager.settings.clear_history()
        return manager.state()

    def _file(job_id: str) -> str:
        try:
            path = manager.filepath_for(job_id)
        except KeyError:
            raise HTTPException(404, "File not found.") from None
        if not path or not os.path.isfile(path):
            raise HTTPException(404, "The file isn't in the folder.")
        return path

    def _missing(action) -> None:
        try:
            action()
        except KeyError:
            raise HTTPException(404, "Item not found.") from None

    return app
