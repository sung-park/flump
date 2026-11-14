"""Turn engine numbers and errors into short UI strings."""

from __future__ import annotations

import re

_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def format_bytes(amount: float | int | None) -> str | None:
    if amount is None or amount < 0:
        return None
    size = float(amount)
    units = ("B", "KB", "MB", "GB", "TB")
    for unit in units:
        if size < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(size)} B"
            return f"{size:.1f} {unit}"
        size /= 1024
    return None


def format_duration(seconds: float | int | None) -> str | None:
    if seconds is None:
        return None
    try:
        total = int(seconds)
    except (TypeError, ValueError):
        return None
    if total < 0:
        return None
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def format_speed(bytes_per_second: float | None) -> str | None:
    label = format_bytes(bytes_per_second)
    if label is None:
        return None
    return f"{label}/s"


def clean_message(message: str) -> str:
    text = _ANSI.sub("", message or "")
    text = re.sub(r"^ERROR:\s*", "", text).strip()
    return text


def humanize_error(message: str) -> str:
    """A short reason shown in the window. The original text stays available as detail."""
    low = clean_message(message).lower()
    if not low:
        return "Couldn't save that."
    if "no video formats" in low or "no formats found" in low:
        return "No video file on this page."
    if "unsupported url" in low or "no suitable extractor" in low or "unable to extract" in low:
        return "No video at this link."
    if "private" in low:
        return "This video is private."
    if "sign in to confirm" in low or "not a bot" in low or "confirm you're not a bot" in low:
        return "The site wants to check that you're a person. Turn on browser cookies in Settings."
    if "sign in" in low or "login" in low or "cookies-from-browser" in low:
        return "This video needs a login. Turn on browser cookies in Settings."
    if "ffmpeg" in low or "merging of multiple formats" in low:
        return "ffmpeg is required. Run brew install ffmpeg."
    if "not available in your country" in low or "geo restricted" in low or "georestricted" in low:
        return "This video isn't available in your region."
    if "removed" in low or "deleted" in low or "unavailable" in low or "copyright" in low:
        return "This video is unavailable. It may have been removed."
    if "no space" in low or "disk full" in low or "not enough space" in low:
        return "Not enough disk space."
    if "timed out" in low or "network" in low or "unable to download" in low or "connection" in low:
        return "The download failed because of a network problem."
    if "requested format is not available" in low:
        return "That quality isn't available. Pick another one in Settings."
    return "Couldn't save that."
