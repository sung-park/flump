"""Settings and finished-download history on disk."""

from __future__ import annotations

import json
import threading
from dataclasses import asdict, dataclass
from pathlib import Path

from flump.platform import default_download_dir, validate_download_dir
from flump.presets import DEFAULT_PRESET, PRESET_BY_ID

COOKIE_BROWSERS = ("safari", "chrome", "whale", "firefox", "edge", "brave")


@dataclass
class Settings:
    download_dir: str
    preset: str = DEFAULT_PRESET
    subtitles: bool = False
    clipboard_watch: bool = False
    concurrent: int = 2
    cookies_browser: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


class SettingsStore:
    def __init__(self, path: Path, history_path: Path, download_dir: Path | None = None):
        self.path = path
        self.history_path = history_path
        self._lock = threading.Lock()
        self.current = self._load(download_dir)
        self.history = self._load_history()

    def _load(self, download_dir: Path | None) -> Settings:
        raw: dict = {}
        if self.path.exists():
            try:
                raw = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                raw = {}
        folder = raw.get("download_dir") or str(download_dir or default_download_dir())
        try:
            folder = str(validate_download_dir(folder))
        except ValueError:
            folder = str(download_dir or default_download_dir())
        preset = raw.get("preset") if raw.get("preset") in PRESET_BY_ID else DEFAULT_PRESET
        cookies = raw.get("cookies_browser") or ""
        if cookies not in COOKIE_BROWSERS:
            cookies = ""
        concurrent = raw.get("concurrent", 2)
        try:
            concurrent = max(1, min(3, int(concurrent)))
        except (TypeError, ValueError):
            concurrent = 2
        return Settings(
            download_dir=folder,
            preset=preset,
            subtitles=bool(raw.get("subtitles", False)),
            clipboard_watch=bool(raw.get("clipboard_watch", False)),
            concurrent=concurrent,
            cookies_browser=cookies,
        )

    def _load_history(self) -> list[dict]:
        if not self.history_path.exists():
            return []
        try:
            data = json.loads(self.history_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        if not isinstance(data, list):
            return []
        return [item for item in data if isinstance(item, dict)][:200]

    def update(self, payload: dict) -> Settings:
        with self._lock:
            data = self.current.to_dict()
            for key in ("preset", "subtitles", "clipboard_watch", "concurrent", "cookies_browser", "download_dir"):
                if key in payload:
                    data[key] = payload[key]
            if data["preset"] not in PRESET_BY_ID:
                raise ValueError("Unknown quality.")
            cookies = data.get("cookies_browser") or ""
            if cookies not in COOKIE_BROWSERS and cookies != "":
                raise ValueError("That browser isn't supported.")
            try:
                concurrent = max(1, min(3, int(data["concurrent"])))
            except (TypeError, ValueError) as exc:
                raise ValueError("Concurrent downloads must be from 1 to 3.") from exc
            folder = str(validate_download_dir(str(data["download_dir"])))
            self.current = Settings(
                download_dir=folder,
                preset=data["preset"],
                subtitles=bool(data["subtitles"]),
                clipboard_watch=bool(data["clipboard_watch"]),
                concurrent=concurrent,
                cookies_browser=cookies,
            )
            self._write(self.path, self.current.to_dict())
            return self.current

    def remember(self, item: dict) -> None:
        with self._lock:
            self.history.insert(0, item)
            del self.history[200:]
            self._write(self.history_path, self.history)

    def clear_history(self) -> None:
        with self._lock:
            self.history.clear()
            self._write(self.history_path, self.history)

    def drop_history(self, item_id: str) -> bool:
        with self._lock:
            kept = [item for item in self.history if item.get("id") != item_id]
            if len(kept) == len(self.history):
                return False
            self.history[:] = kept
            self._write(self.history_path, self.history)
            return True

    def snapshot(self) -> tuple[Settings, list[dict]]:
        with self._lock:
            return self.current, list(self.history)

    @staticmethod
    def _write(path: Path, payload) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(path)
