"""Folders, clipboard, and Finder. The download server never leaves this machine."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


def app_support_dir() -> Path:
    if sys.platform == "darwin":
        root = Path.home() / "Library" / "Application Support" / "Flump"
    elif sys.platform == "win32":
        root = Path(os.environ.get("APPDATA", str(Path.home()))) / "Flump"
    else:
        config = os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
        root = Path(config) / "flump"
    root.mkdir(parents=True, exist_ok=True)
    return root


def default_download_dir() -> Path:
    root = Path.home() / "Downloads" / "Flump"
    root.mkdir(parents=True, exist_ok=True)
    return root


def ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def js_runtime_name() -> str | None:
    """yt-dlp needs one of these to solve YouTube's script challenges."""
    for name in ("deno", "node", "bun", "qjs"):
        if shutil.which(name):
            return "quickjs" if name == "qjs" else name
    return None


def validate_download_dir(path: str) -> Path:
    folder = Path(path).expanduser().resolve()
    if folder == Path(folder.anchor):
        raise ValueError("Can't save to that folder.")
    folder.mkdir(parents=True, exist_ok=True)
    if not folder.is_dir() or not os.access(folder, os.W_OK):
        raise ValueError("Can't write to that folder.")
    return folder


def read_clipboard() -> str:
    if sys.platform != "darwin":
        return ""
    try:
        result = subprocess.run(
            ["pbpaste"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout or ""


def pick_folder() -> str | None:
    """Native folder panel. macOS only; other systems edit the path in settings."""
    if sys.platform != "darwin":
        return None
    script = 'POSIX path of (choose folder with prompt "Choose a folder for videos")'
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    chosen = result.stdout.strip()
    return chosen or None


def reveal_path(path: str) -> None:
    if sys.platform == "darwin":
        subprocess.run(["open", "-R", path], check=False)
    elif sys.platform == "win32":
        subprocess.run(["explorer", "/select,", os.path.normpath(path)], check=False)
    else:
        subprocess.run(["xdg-open", str(Path(path).parent)], check=False)


def open_path(path: str) -> None:
    if sys.platform == "darwin":
        subprocess.run(["open", path], check=False)
    elif sys.platform == "win32":
        os.startfile(path)  # type: ignore[attr-defined]
    else:
        subprocess.run(["xdg-open", path], check=False)
