"""Queue. Probing and downloading run off the request thread."""

from __future__ import annotations

import queue
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field

from yt_dlp.utils import DownloadCancelled

from flump.engine import DownloadOptions, EngineError
from flump.platform import ffmpeg_available, js_runtime_name
from flump.present import humanize_error
from flump.presets import PRESETS
from flump.settings import SettingsStore
from flump.urls import clipboard_is_only_urls, extract_urls

_ACTIVE = {"queued", "extracting", "downloading", "processing"}
_CLIPBOARD_GRACE = 20


@dataclass
class Job:
    id: str
    url: str
    title: str
    status: str
    kind: str = "video"
    thumbnail: str | None = None
    extractor: str | None = None
    duration: str | None = None
    percent: float | None = None
    speed: str | None = None
    eta: str | None = None
    size: str | None = None
    filepath: str | None = None
    error: str | None = None
    error_detail: str | None = None
    warning: str | None = None
    entries: list[dict] = field(default_factory=list)
    truncated: bool = False
    playlist_items: str | None = None
    source: str = "paste"
    created_at: float = 0

    def to_dict(self) -> dict:
        return asdict(self)


class JobManager:
    def __init__(self, engine, settings: SettingsStore, clipboard_reader=None, clipboard_interval: float = 1.2):
        self.engine = engine
        self.settings = settings
        self.clipboard_reader = clipboard_reader
        self.clipboard_interval = clipboard_interval
        self.jobs: dict[str, Job] = {}
        self.cancels: dict[str, threading.Event] = {}
        self._lock = threading.Lock()
        self._queue: queue.Queue = queue.Queue()
        self._stopped = threading.Event()
        self._threads: list[threading.Thread] = []
        self._active_downloads = 0
        self._recent: dict[str, float] = {}
        self._last_clipboard = ""

    def start(self) -> None:
        if self._threads:
            return
        self._stopped.clear()
        for index in range(3):
            thread = threading.Thread(target=self._worker, name=f"flump-worker-{index}", daemon=True)
            thread.start()
            self._threads.append(thread)
        watcher = threading.Thread(target=self._watch_clipboard, name="flump-clipboard", daemon=True)
        watcher.start()
        self._threads.append(watcher)

    def stop(self) -> None:
        self._stopped.set()
        with self._lock:
            for event in self.cancels.values():
                event.set()
        for thread in self._threads:
            thread.join(timeout=0.5)
        self._threads.clear()

    def submit_text(self, text: str, source: str = "paste") -> list[str]:
        urls = extract_urls(text or "")
        if not urls:
            raise ValueError("No link found.")
        ids = []
        for url in urls:
            ids.append(self._enqueue(url, source=source))
        return ids

    def cancel(self, job_id: str) -> None:
        with self._lock:
            event = self.cancels.get(job_id)
            job = self.jobs.get(job_id)
            if event is None or job is None:
                raise KeyError(job_id)
            event.set()
            if job.status in {"queued", "extracting", "review"}:
                job.status = "cancelled"

    def dismiss(self, job_id: str) -> None:
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None:
                raise KeyError(job_id)
            if job.status in _ACTIVE:
                raise ValueError("Cancel the download before removing it.")
            self.jobs.pop(job_id, None)
            self.cancels.pop(job_id, None)

    def retry(self, job_id: str) -> str:
        _, history_items = self.settings.snapshot()
        with self._lock:
            job = self.jobs.get(job_id)
        history = None
        if job is None:
            history = next((item for item in history_items if item.get("id") == job_id), None)
        if job is None and history is None:
            raise KeyError(job_id)
        with self._lock:
            url = job.url if job else history["url"]
            playlist_items = job.playlist_items if job else history.get("playlist_items")
            title = job.title if job else history.get("title")
        return self._enqueue(url, source="paste", playlist_items=playlist_items, title=title, known=bool(playlist_items))

    def download_entries(self, job_id: str, indexes: list[int] | None) -> list[str]:
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None or job.kind != "playlist":
                raise KeyError(job_id)
            chosen = job.entries
            if indexes is not None:
                wanted = set(indexes)
                chosen = [entry for entry in job.entries if entry["index"] in wanted]
            if not chosen:
                raise ValueError("Choose a video to save.")
            url = job.url
            picked = list(chosen)
            self.jobs.pop(job_id, None)
            self.cancels.pop(job_id, None)
        ids = []
        for entry in picked:
            ids.append(
                self._enqueue(
                    url,
                    source="paste",
                    title=entry["title"],
                    duration=entry.get("duration"),
                    playlist_items=str(entry["index"]),
                    known=True,
                )
            )
        return ids

    def filepath_for(self, job_id: str) -> str:
        with self._lock:
            job = self.jobs.get(job_id)
            if job and job.filepath:
                return job.filepath
        for item in self.settings.snapshot()[1]:
            if item.get("id") == job_id and item.get("filepath"):
                return item["filepath"]
        raise KeyError(job_id)

    def state(self) -> dict:
        settings, history = self.settings.snapshot()
        with self._lock:
            jobs = [job.to_dict() for job in self.jobs.values()]
        jobs.sort(key=lambda item: item["created_at"])
        return {
            "jobs": jobs,
            "history": history,
            "settings": settings.to_dict(),
            "ffmpeg": ffmpeg_available(),
            "js_runtime": js_runtime_name(),
            "presets": [{"id": preset.id, "label": preset.label} for preset in PRESETS],
        }

    def _enqueue(
        self,
        url: str,
        source: str,
        title: str | None = None,
        duration: str | None = None,
        playlist_items: str | None = None,
        known: bool = False,
    ) -> str:
        job = Job(
            id=uuid.uuid4().hex[:12],
            url=url,
            title=title or url,
            status="queued" if known else "extracting",
            duration=duration,
            playlist_items=playlist_items,
            source=source,
            created_at=time.time(),
        )
        event = threading.Event()
        with self._lock:
            self.jobs[job.id] = job
            self.cancels[job.id] = event
            self._recent[url] = time.time()
        if known:
            self._queue.put(lambda job_id=job.id: self._run_download(job_id))
        else:
            self._queue.put(lambda job_id=job.id: self._run_probe(job_id))
        return job.id

    def _worker(self) -> None:
        while not self._stopped.is_set():
            try:
                task = self._queue.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                task()
            except Exception:
                # The task itself records expected failures. This guards the worker.
                pass
            finally:
                self._queue.task_done()

    def _watch_clipboard(self) -> None:
        while not self._stopped.wait(self.clipboard_interval):
            settings, _ = self.settings.snapshot()
            if not settings.clipboard_watch or self.clipboard_reader is None:
                continue
            try:
                text = self.clipboard_reader() or ""
            except Exception:
                continue
            if not text or text == self._last_clipboard or not clipboard_is_only_urls(text):
                self._last_clipboard = text
                continue
            self._last_clipboard = text
            now = time.time()
            with self._lock:
                active = {job.url for job in self.jobs.values() if job.status in _ACTIVE or job.status == "review"}
                fresh = []
                for url in extract_urls(text):
                    if url in active or now - self._recent.get(url, 0) < _CLIPBOARD_GRACE:
                        continue
                    fresh.append(url)
            for url in fresh:
                self._enqueue(url, source="clipboard")

    def _run_probe(self, job_id: str) -> None:
        with self._lock:
            job = self.jobs.get(job_id)
            cancel = self.cancels.get(job_id)
            if job is None or cancel is None or cancel.is_set():
                self._mark_cancelled(job_id)
                return
            url = job.url
        try:
            result = self.engine.probe(url)
        except Exception as exc:
            self._fail(job_id, exc)
            return
        if cancel.is_set():
            self._mark_cancelled(job_id)
            return
        if result.kind == "playlist":
            with self._lock:
                job = self.jobs.get(job_id)
                if job is None:
                    return
                job.kind = "playlist"
                job.status = "review"
                job.title = result.title
                job.extractor = result.extractor
                job.thumbnail = result.thumbnail
                job.truncated = result.truncated
                job.entries = [asdict(entry) for entry in result.entries]
            return
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None:
                return
            job.title = result.title
            job.extractor = result.extractor
            job.thumbnail = result.thumbnail
            job.duration = result.duration
            if result.playlist_items and not job.playlist_items:
                job.playlist_items = result.playlist_items
            job.status = "queued"
        self._run_download(job_id)

    def _run_download(self, job_id: str) -> None:
        if not self._acquire_slot(job_id):
            self._mark_cancelled(job_id)
            return
        try:
            settings, _ = self.settings.snapshot()
            with self._lock:
                job = self.jobs.get(job_id)
                cancel = self.cancels.get(job_id)
                if job is None or cancel is None or cancel.is_set() or job.status == "cancelled":
                    return
                job.status = "downloading"
                options = DownloadOptions(
                    download_dir=settings.download_dir,
                    preset=settings.preset,
                    subtitles=settings.subtitles,
                    cookies_browser=settings.cookies_browser,
                    playlist_items=job.playlist_items,
                )
                url = job.url

            def on_progress(**kwargs):
                self._apply_progress(job_id, kwargs)

            path = self.engine.download(url, options, on_progress, cancel)
            self._complete(job_id, path)
        except DownloadCancelled:
            self._mark_cancelled(job_id)
        except Exception as exc:
            self._fail(job_id, exc)
        finally:
            with self._lock:
                self._active_downloads = max(0, self._active_downloads - 1)

    def _acquire_slot(self, job_id: str) -> bool:
        while not self._stopped.is_set():
            settings, _ = self.settings.snapshot()
            with self._lock:
                cancel = self.cancels.get(job_id)
                job = self.jobs.get(job_id)
                if cancel is None or job is None or cancel.is_set() or job.status == "cancelled":
                    return False
                if self._active_downloads < settings.concurrent:
                    self._active_downloads += 1
                    return True
            if self._stopped.wait(0.2):
                return False
        return False

    def _apply_progress(self, job_id: str, payload: dict) -> None:
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None or job.status in {"done", "error", "cancelled"}:
                return
            phase = payload.get("phase")
            if phase:
                job.status = phase
            if payload.get("percent") is not None:
                job.percent = payload["percent"]
            for key in ("speed", "eta", "size", "warning"):
                if payload.get(key):
                    setattr(job, key, payload[key])
            if payload.get("title"):
                job.title = payload["title"]
            if payload.get("thumbnail"):
                job.thumbnail = payload["thumbnail"]
            if payload.get("extractor"):
                job.extractor = payload["extractor"]
            if payload.get("duration"):
                job.duration = payload["duration"]

    def _complete(self, job_id: str, path: str) -> None:
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None:
                return
            job.status = "done"
            job.filepath = path
            job.percent = 100
            job.error = None
            item = job.to_dict()
            self.jobs.pop(job_id, None)
            self.cancels.pop(job_id, None)
        self.settings.remember(item)

    def _fail(self, job_id: str, exc: Exception) -> None:
        detail = getattr(exc, "detail", None) or str(exc)
        detail = (detail or "").strip()[:500]
        message = humanize_error(detail)
        if isinstance(exc, EngineError) and exc.args:
            # EngineError's message is already the extractor text. Prefer the short form
            # unless humanize fell back to the generic line and the detail is already short Korean.
            if message == "Couldn't save that." and detail and len(detail) < 180 and "ERROR" not in detail:
                message = detail
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None or job.status == "cancelled":
                return
            job.status = "error"
            job.error = message
            job.error_detail = detail or None

    def _mark_cancelled(self, job_id: str) -> None:
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None or job.status == "done":
                return
            job.status = "cancelled"
            job.error = None
