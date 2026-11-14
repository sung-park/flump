import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from yt_dlp.utils import DownloadCancelled

from flump.engine import EngineError, ProbeEntry, ProbeResult
from flump.jobs import JobManager
from flump.platform import validate_download_dir
from flump.server import create_app
from flump.settings import SettingsStore


class Clipboard:
    def __init__(self):
        self.value = ""

    def __call__(self):
        return self.value


class FakeEngine:
    def __init__(self):
        self.probes = {}
        self.calls = []
        self.hold = threading.Event()
        self.block = False
        self.fail = None

    def probe(self, url):
        result = self.probes.get(url)
        if isinstance(result, Exception):
            raise result
        if result is not None:
            return result
        return ProbeResult(kind="video", title="샘플 Video", extractor="Example", duration="0:05", thumbnail="https://cdn.example/t.jpg")

    def download(self, url, options, on_progress, cancel_event):
        self.calls.append((url, options.playlist_items, options.preset))
        if self.block:
            self.hold.wait(3)
        if cancel_event.is_set():
            raise DownloadCancelled("cancelled")
        if self.fail:
            raise self.fail
        on_progress(phase="downloading", percent=40, speed="1.0 MB/s", eta="0:01", size="1.0 MB")
        path = Path(options.download_dir) / "sample.mp4"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"video")
        return str(path)


@pytest.fixture
def client(tmp_path):
    engine = FakeEngine()
    store = SettingsStore(tmp_path / "settings.json", tmp_path / "history.json", download_dir=tmp_path / "Flump")
    clipboard = Clipboard()
    manager = JobManager(engine, store, clipboard_reader=clipboard, clipboard_interval=0.05)
    app = create_app(manager)
    with TestClient(app) as test_client:
        test_client.engine = engine
        test_client.clipboard = clipboard
        test_client.store = store
        yield test_client


def wait_until(predicate, timeout=3):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def test_page_and_local_origin(client):
    page = client.get("/")
    assert page.status_code == 200
    assert "Video link" in page.text
    assert client.get("/static/app.js").status_code == 200
    blocked = client.get("/api/state", headers={"Origin": "https://evil.example"})
    assert blocked.status_code == 403
    allowed = client.get("/api/state", headers={"Origin": "http://127.0.0.1:47321"})
    assert allowed.status_code == 200
    assert allowed.json()["settings"]["preset"] == "best_mp4"


def test_paste_downloads_the_video(client):
    response = client.post("/api/submit", json={"text": "여기요 https://videos.example/watch?v=1 입니다."})
    assert response.status_code == 200
    assert wait_until(lambda: client.engine.calls)
    state = client.get("/api/state").json()
    assert state["jobs"] == []
    assert state["history"][0]["title"] == "샘플 Video"
    assert state["history"][0]["status"] == "done"
    assert Path(state["history"][0]["filepath"]).is_file()


def test_playlist_waits_for_a_choice(client):
    url = "https://videos.example/playlist?list=abc"
    client.engine.probes[url] = ProbeResult(
        kind="playlist",
        title="시리즈",
        extractor="YouTube",
        entries=[ProbeEntry(1, "하나", "1:00"), ProbeEntry(2, "둘", "2:00")],
    )
    client.post("/api/submit", json={"text": url})
    assert wait_until(lambda: client.get("/api/state").json()["jobs"])
    job = client.get("/api/state").json()["jobs"][0]
    assert job["status"] == "review"
    assert [entry["title"] for entry in job["entries"]] == ["하나", "둘"]
    assert client.engine.calls == []

    chosen = client.post(f"/api/jobs/{job['id']}/entries", json={"indexes": [2]})
    assert chosen.status_code == 200
    assert wait_until(lambda: client.engine.calls == [(url, "2", "best_mp4")])
    assert wait_until(lambda: client.get("/api/state").json()["history"])
    assert client.get("/api/state").json()["history"][0]["title"] == "둘"


def test_cancel_stops_the_download(client):
    client.engine.block = True
    client.engine.hold.clear()
    client.post("/api/submit", json={"text": "https://videos.example/slow"})
    assert wait_until(lambda: client.engine.calls)
    job_id = client.get("/api/state").json()["jobs"][0]["id"]
    assert client.post(f"/api/jobs/{job_id}/cancel").status_code == 200
    client.engine.hold.set()
    assert wait_until(lambda: client.get("/api/state").json()["jobs"][0]["status"] == "cancelled")


def test_failure_is_explained(client):
    client.engine.fail = EngineError("Unsupported URL: https://nope.example", "Unsupported URL: https://nope.example")
    client.post("/api/submit", json={"text": "https://nope.example/x"})
    assert wait_until(lambda: client.get("/api/state").json()["jobs"] and client.get("/api/state").json()["jobs"][0]["status"] == "error")
    job = client.get("/api/state").json()["jobs"][0]
    assert job["error"] == "No video at this link."


def test_empty_paste_is_rejected(client):
    response = client.post("/api/submit", json={"text": "주소가 없는 문장"})
    assert response.status_code == 400


def test_settings_roundtrip_and_bad_preset(client):
    saved = client.put("/api/settings", json={"preset": "720", "subtitles": True, "concurrent": 1})
    assert saved.status_code == 200
    assert saved.json()["settings"]["preset"] == "720"
    assert saved.json()["settings"]["concurrent"] == 1
    again = client.get("/api/state").json()["settings"]
    assert again["subtitles"] is True
    refused = client.put("/api/settings", json={"preset": "nope"})
    assert refused.status_code == 400


def test_clipboard_watch_takes_a_bare_url(client):
    client.put("/api/settings", json={"clipboard_watch": True})
    client.clipboard.value = "https://videos.example/from-clipboard"
    assert wait_until(lambda: client.get("/api/state").json()["history"], timeout=3)
    assert client.get("/api/state").json()["history"][0]["source"] == "clipboard"


def test_clipboard_ignores_prose(client):
    client.put("/api/settings", json={"clipboard_watch": True})
    client.clipboard.value = "읽어 보세요 https://videos.example/inside-article"
    time.sleep(0.2)
    assert client.get("/api/state").json()["jobs"] == []
    assert client.get("/api/state").json()["history"] == []


def test_download_dir_rejects_filesystem_root():
    with pytest.raises(ValueError):
        validate_download_dir("/")
