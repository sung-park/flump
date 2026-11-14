"""Pull http(s) URLs out of text the user pasted or dropped."""

from __future__ import annotations

import re

_URL = re.compile(r"https?://[^\s<>\"'`]+", re.IGNORECASE)
_TRAILING = ".,;:)]}>\"'`"
_MAX_URLS = 30


def extract_urls(text: str, limit: int = _MAX_URLS) -> list[str]:
    """Return unique http(s) URLs in the order they appear."""
    if not text:
        return []
    found: list[str] = []
    seen: set[str] = set()
    for match in _URL.findall(text):
        url = match.rstrip(_TRAILING)
        if len(url) < 8 or url in seen:
            continue
        seen.add(url)
        found.append(url)
        if len(found) >= limit:
            break
    return found


def clipboard_is_only_urls(text: str) -> bool:
    """True when the clipboard is one or more URLs and nothing else.

    A copied article that happens to contain a link should not start a download.
    """
    urls = extract_urls(text)
    if not urls:
        return False
    remainder = text.strip()
    for url in urls:
        remainder = remainder.replace(url, "")
    return remainder.strip() == ""
