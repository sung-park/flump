from flump.present import format_bytes, format_duration, humanize_error
from flump.urls import clipboard_is_only_urls, extract_urls


def test_extract_urls_strips_punctuation_and_dedupes():
    text = "see https://youtu.be/abc, and https://vimeo.com/1. again https://youtu.be/abc"
    assert extract_urls(text) == ["https://youtu.be/abc", "https://vimeo.com/1"]


def test_extract_urls_ignores_bare_words():
    assert extract_urls("유튜브에서 검색해 보세요") == []


def test_clipboard_only_counts_url_text():
    assert clipboard_is_only_urls("https://a.example/one\nhttps://b.example/two")
    assert not clipboard_is_only_urls("기사입니다 https://a.example/one 읽어 보세요")


def test_formatters():
    assert format_bytes(1536) == "1.5 KB"
    assert format_duration(75) == "1:15"
    assert format_duration(3661) == "1:01:01"


def test_humanize_known_failures():
    assert humanize_error("ERROR: Unsupported URL: https://example.com") == "No video at this link."
    assert "cookies" in humanize_error("Sign in to confirm you’re not a bot")
    assert "ffmpeg" in humanize_error("You have requested merging of multiple formats but ffmpeg is not installed")
