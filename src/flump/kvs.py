"""Direct file address hidden in a Kernel Video Sharing player page.

yt-dlp's generic extractor skips `video_url` unless the value already contains
`/get_file/`. These pages store that address as base64.
"""

from __future__ import annotations

import base64
import re
import urllib.request

_URL_RE = re.compile(
    r"(video_(?:url(?:_hd)?|alt_url\d*))\s*:\s*['\"]([^'\"]+)['\"]",
    re.IGNORECASE,
)
_TITLE_RE = re.compile(r"video_title\s*:\s*'([^']*)'", re.IGNORECASE)


def kvs_direct_url(html: str) -> tuple[str, str | None] | None:
    lowered = html.lower()
    if "flashvars" not in lowered and "kt_player" not in lowered:
        return None
    best_rank = -1
    best_url = None
    for key, raw in _URL_RE.findall(html):
        url = _decode(raw)
        if not url:
            continue
        key_low = key.lower()
        rank = 2 if key_low.endswith("_hd") else (1 if "alt_" in key_low else 0)
        if rank > best_rank:
            best_rank = rank
            best_url = url
    if not best_url:
        return None
    title = None
    match = _TITLE_RE.search(html)
    if match:
        title = match.group(1).replace("\\'", "'").replace("\\/", "/").strip()[:300] or None
    return best_url, title


def fetch_html(url: str) -> str | None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0", "Accept": "text/html"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read(2_000_000)
            charset = response.headers.get_content_charset() or "utf-8"
            return raw.decode(charset, "replace")
    except Exception:
        return None


def safe_stem(title: str) -> str:
    cleaned = re.sub(r"[\\/:\n\r%\"]", " ", title)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned[:180] or "video"


def _decode(raw: str) -> str | None:
    text = raw.strip()
    if text.startswith(("http://", "https://")):
        return text
    padded = text + ("=" * ((4 - len(text) % 4) % 4))
    try:
        decoded = base64.b64decode(padded, validate=False).decode("utf-8").strip()
    except Exception:
        return None
    if decoded.startswith(("http://", "https://")):
        return decoded
    return None
