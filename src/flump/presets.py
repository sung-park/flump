"""Quality choices. Merging separate video and audio needs ffmpeg."""

from __future__ import annotations

from dataclasses import dataclass


class NeedsTool(Exception):
    """The chosen preset cannot run without ffmpeg."""


@dataclass(frozen=True)
class Preset:
    id: str
    label: str
    format: str
    merge: str | None
    audio: str | None
    needs_ffmpeg: bool


PRESETS: tuple[Preset, ...] = (
    Preset(
        "best_mp4",
        "Best MP4",
        "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b",
        "mp4",
        None,
        True,
    ),
    Preset("best", "Best", "bv*+ba/b", None, None, True),
    Preset(
        "1080",
        "1080p",
        "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b",
        "mp4",
        None,
        True,
    ),
    Preset(
        "720",
        "720p",
        "bv*[height<=720]+ba/b[height<=720]/bv*+ba/b",
        "mp4",
        None,
        True,
    ),
    Preset("audio_m4a", "Audio M4A", "ba[ext=m4a]/ba/b", None, "m4a", True),
    Preset("audio_mp3", "Audio MP3", "ba/b", None, "mp3", True),
)

PRESET_BY_ID = {preset.id: preset for preset in PRESETS}
DEFAULT_PRESET = "best_mp4"

_SINGLE_FILE = {
    "best_mp4": "b",
    "best": "b",
    "1080": "b[height<=1080]/b",
    "720": "b[height<=720]/b",
}


def resolve_preset(preset_id: str, has_ffmpeg: bool) -> tuple[Preset, str | None]:
    """Return the preset to run, and a warning if ffmpeg forced a fallback."""
    preset = PRESET_BY_ID.get(preset_id)
    if preset is None:
        raise ValueError("Unknown quality.")
    if not preset.needs_ffmpeg or has_ffmpeg:
        return preset, None
    if preset.audio:
        raise NeedsTool("Audio-only downloads need ffmpeg. Run brew install ffmpeg.")
    fallback = Preset(
        preset.id,
        preset.label,
        _SINGLE_FILE.get(preset.id, "b"),
        None,
        None,
        False,
    )
    return fallback, "ffmpeg isn't installed, so Flump saves a file that already has picture and sound together."
