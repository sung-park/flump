import base64

from flump.kvs import kvs_direct_url
from flump.present import humanize_error


def test_kvs_decodes_video_url_and_prefers_hd():
    low = base64.b64encode(b"https://cdn.example/get_file/1/a.mp4").decode()
    hd = base64.b64encode(b"https://cdn.example/get_file/1/a_hd.mp4").decode()
    html = f"""
    var flashvars = {{
      video_title: 'Sample clip',
      video_url: '{low}',
      video_url_hd: '{hd}',
    }};
    """
    url, title = kvs_direct_url(html)
    assert url == "https://cdn.example/get_file/1/a_hd.mp4"
    assert title == "Sample clip"


def test_kvs_skips_placeholder_and_unrelated_pages():
    low = base64.b64encode(b"https://cdn.example/get_file/1/a.mp4").decode()
    html = f"kt_player(); var flashvars = {{ video_url: '{low}', video_url_hd: 'MQ==' }};"
    url, title = kvs_direct_url(html)
    assert url == "https://cdn.example/get_file/1/a.mp4"
    assert title is None
    assert kvs_direct_url("<html>no player</html>") is None
    assert humanize_error("ERROR: [generic] 1: No video formats found!") == "No video file on this page."
