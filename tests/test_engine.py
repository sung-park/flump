import pytest

from flump.engine import DownloadOptions, build_ydl_opts
from flump.presets import NeedsTool, resolve_preset


def test_mp4_preset_merges_when_ffmpeg_exists():
    options = DownloadOptions(
        download_dir="/tmp/ply",
        preset="best_mp4",
        subtitles=True,
        cookies_browser="safari",
        playlist_items="3",
    )
    opts, warning = build_ydl_opts(options, has_ffmpeg=True)
    assert warning is None
    assert opts["merge_output_format"] == "mp4"
    assert opts["noplaylist"] is False
    assert opts["playlist_items"] == "3"
    assert opts["cookiesfrombrowser"] == ("safari",)
    assert opts["writesubtitles"] is True
    assert opts["subtitleslangs"] == ["ko", "ko-KR", "en"]


def test_single_video_does_not_pull_a_playlist():
    options = DownloadOptions("/tmp/ply", "best", False, "")
    opts, _ = build_ydl_opts(options, has_ffmpeg=True)
    assert opts["noplaylist"] is True
    assert "playlist_items" not in opts


def test_missing_ffmpeg_falls_back_to_a_single_file():
    preset, warning = resolve_preset("1080", has_ffmpeg=False)
    assert preset.format == "b[height<=1080]/b"
    assert preset.merge is None
    assert warning


def test_audio_without_ffmpeg_is_refused():
    with pytest.raises(NeedsTool):
        resolve_preset("audio_mp3", has_ffmpeg=False)


def test_unknown_preset():
    with pytest.raises(ValueError):
        resolve_preset("ultra", has_ffmpeg=True)
