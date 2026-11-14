"""yt-dlp adapter. Probe a page, then download one video."""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from pathlib import Path

from yt_dlp.utils import DownloadCancelled, YoutubeDLError

from flump.kvs import fetch_html, kvs_direct_url, safe_stem
from flump.platform import ffmpeg_available
from flump.present import clean_message, format_bytes, format_duration, format_speed
from flump.presets import NeedsTool, resolve_preset

_PLAYLIST_CAP = 100
_JS_RUNTIMES = {"deno": {}, "node": {}, "bun": {}, "quickjs": {}}


def _quiet_opts() -> dict:
    return {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "color": "no_color",
        "js_runtimes": {name: {} for name in _JS_RUNTIMES},
    }


@dataclass(frozen=True)
class DownloadOptions:
    download_dir: str
    preset: str
    subtitles: bool
    cookies_browser: str
    playlist_items: str | None = None


@dataclass
class ProbeEntry:
    index: int
    title: str
    duration: str | None = None


@dataclass
class ProbeResult:
    kind: str
    title: str
    extractor: str | None = None
    thumbnail: str | None = None
    duration: str | None = None
    entries: list[ProbeEntry] = field(default_factory=list)
    truncated: bool = False
    playlist_items: str | None = None


class EngineError(Exception):
    def __init__(self, message: str, detail: str = ""):
        super().__init__(message)
        self.detail = detail or message


def build_ydl_opts(options: DownloadOptions, has_ffmpeg: bool) -> tuple[dict, str | None]:
    preset, warning = resolve_preset(options.preset, has_ffmpeg)
    outtmpl = str(Path(options.download_dir) / "%(title).180B [%(id)s].%(ext)s")
    opts: dict = {
        **_quiet_opts(),
        "format": preset.format,
        "outtmpl": {"default": outtmpl},
        "paths": {"home": options.download_dir},
        "retries": 10,
        "fragment_retries": 10,
        "concurrent_fragment_downloads": 4,
        "continuedl": True,
        "ignoreerrors": False,
        "noplaylist": options.playlist_items is None,
        "windowsfilenames": os.name == "nt",
    }
    if options.playlist_items:
        opts["noplaylist"] = False
        opts["playlist_items"] = options.playlist_items
    if preset.merge:
        opts["merge_output_format"] = preset.merge
    if preset.audio:
        opts["final_ext"] = preset.audio
        opts["postprocessors"] = [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": preset.audio,
                "preferredquality": "0",
            }
        ]
    if options.subtitles and not preset.audio:
        opts["writesubtitles"] = True
        opts["writeautomaticsub"] = True
        opts["subtitleslangs"] = ["ko", "ko-KR", "en"]
        opts["subtitlesformat"] = "srt/best"
    if options.cookies_browser:
        opts["cookiesfrombrowser"] = (options.cookies_browser,)
    return opts, warning


def _thumbnail(info: dict) -> str | None:
    thumb = info.get("thumbnail")
    if isinstance(thumb, str) and thumb.startswith(("http://", "https://")):
        return thumb
    for item in reversed(info.get("thumbnails") or []):
        url = item.get("url") if isinstance(item, dict) else None
        if isinstance(url, str) and url.startswith(("http://", "https://")):
            return url
    return None


def _title(info: dict, fallback: str) -> str:
    title = info.get("title") or fallback
    title = str(title).strip() or fallback
    return title[:300]


class YtDlpEngine:
    def probe(self, url: str) -> ProbeResult:
        opts = {
            **_quiet_opts(),
            "skip_download": True,
            "extract_flat": "in_playlist",
            "playlistend": _PLAYLIST_CAP,
            "lazy_playlist": False,
            "ignoreerrors": True,
            # A watch URL that also names a playlist downloads that video.
            # A playlist URL still comes back as a playlist.
            "noplaylist": True,
        }
        info = self._extract(url, opts, download=False)
        if not info:
            raise EngineError("No video at this link.")
        if info.get("_type") == "playlist":
            return self._playlist(info, url)
        return ProbeResult(
            kind="video",
            title=_title(info, url),
            extractor=info.get("extractor_key") or info.get("extractor"),
            thumbnail=_thumbnail(info),
            duration=format_duration(info.get("duration")),
        )

    def _playlist(self, info: dict, url: str) -> ProbeResult:
        entries: list[ProbeEntry] = []
        for index, entry in enumerate(info.get("entries") or [], start=1):
            if not entry:
                continue
            entries.append(
                ProbeEntry(
                    index=index,
                    title=_title(entry, f"Item {index}"),
                    duration=format_duration(entry.get("duration")),
                )
            )
        count = info.get("playlist_count") or info.get("n_entries")
        truncated = bool(count and count > len(entries)) or len(entries) >= _PLAYLIST_CAP
        if not entries:
            raise EngineError("No video at this link.")
        if len(entries) == 1 and not truncated:
            only = entries[0]
            return ProbeResult(
                kind="video",
                title=only.title,
                extractor=info.get("extractor_key") or info.get("extractor"),
                thumbnail=_thumbnail(info) or _thumbnail((info.get("entries") or [{}])[0] or {}),
                duration=only.duration,
                playlist_items=str(only.index),
            )
        return ProbeResult(
            kind="playlist",
            title=_title(info, url),
            extractor=info.get("extractor_key") or info.get("extractor"),
            thumbnail=_thumbnail(info),
            entries=entries,
            truncated=truncated,
        )

    def download(self, url: str, options: DownloadOptions, on_progress, cancel_event) -> str:
        from yt_dlp import YoutubeDL

        try:
            ydl_opts, warning = build_ydl_opts(options, ffmpeg_available())
        except NeedsTool as exc:
            raise EngineError(str(exc), str(exc)) from exc
        if warning:
            on_progress(warning=warning)

        final_path: dict[str, str | None] = {"path": None}
        last_emit = {"at": 0.0}

        def hook(status: dict) -> None:
            if cancel_event.is_set():
                raise DownloadCancelled("cancelled")
            state = status.get("status")
            now = time.monotonic()
            if state == "downloading" and now - last_emit["at"] < 0.25:
                return
            last_emit["at"] = now
            info = status.get("info_dict") or {}
            total = status.get("total_bytes") or status.get("total_bytes_estimate")
            downloaded = status.get("downloaded_bytes")
            percent = None
            if total and downloaded is not None:
                percent = max(0.0, min(100.0, downloaded / total * 100))
            elif status.get("fragment_count"):
                index = status.get("fragment_index") or 0
                percent = max(0.0, min(100.0, index / status["fragment_count"] * 100))
            payload = {
                "phase": "processing" if state == "finished" else "downloading",
                "speed": format_speed(status.get("speed")),
                "eta": format_duration(status.get("eta")),
                "size": format_bytes(total or downloaded),
                "title": _title(info, "") if info.get("title") else None,
                "thumbnail": _thumbnail(info),
                "extractor": info.get("extractor_key") or info.get("extractor"),
                "duration": format_duration(info.get("duration")),
            }
            if percent is not None:
                payload["percent"] = round(percent, 1)
            on_progress(**payload)

        def pp_hook(status: dict) -> None:
            if cancel_event.is_set():
                raise DownloadCancelled("cancelled")
            if status.get("status") in {"started", "processing"}:
                on_progress(phase="processing", percent=100)

        def post_hook(filepath: str) -> None:
            final_path["path"] = filepath

        ydl_opts["progress_hooks"] = [hook]
        ydl_opts["postprocessor_hooks"] = [pp_hook]
        ydl_opts["post_hooks"] = [post_hook]

        try:
            info = self._extract(url, ydl_opts, download=True)
        except DownloadCancelled:
            raise

        path = final_path["path"]
        if not path and info:
            for item in reversed(info.get("requested_downloads") or []):
                candidate = item.get("filepath")
                if candidate and os.path.exists(candidate) and not str(candidate).endswith(".part"):
                    path = candidate
                    break
        if not path or not os.path.exists(path):
            raise EngineError("The file wasn't saved.")
        return path

    def _extract(self, url: str, opts: dict, download: bool):
        from yt_dlp import YoutubeDL

        try:
            with YoutubeDL(opts) as ydl:
                return ydl.extract_info(url, download=download)
        except DownloadCancelled:
            raise
        except YoutubeDLError as exc:
            detail = clean_message(str(exc))
            low = detail.lower()
            if not any(token in low for token in ("no video formats", "unsupported url", "unable to extract")):
                raise EngineError(detail, detail) from exc
            html = fetch_html(url) or ""
            resolved = kvs_direct_url(html)
            if not resolved:
                raise EngineError(detail, detail) from exc
            media, title = resolved
            retry = dict(opts)
            headers = dict(retry.get("http_headers") or {})
            headers["Referer"] = url
            retry["http_headers"] = headers
            home = (retry.get("paths") or {}).get("home")
            if download and title and home:
                retry["outtmpl"] = {"default": str(Path(home) / f"{safe_stem(title)} [%(id)s].%(ext)s")}
            try:
                with YoutubeDL(retry) as ydl:
                    info = ydl.extract_info(media, download=download)
            except DownloadCancelled:
                raise
            except YoutubeDLError as exc2:
                detail2 = clean_message(str(exc2))
                raise EngineError(detail2, detail2) from exc2
            if isinstance(info, dict) and title:
                current = str(info.get("title") or "")
                ident = str(info.get("id") or "")
                if not current or current in {ident, url}:
                    info["title"] = title
            return info
