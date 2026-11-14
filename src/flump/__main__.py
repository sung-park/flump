"""Open Flump in the browser and keep the downloader running."""

from __future__ import annotations

import argparse
import socket
import sys
import threading
import webbrowser

import uvicorn

from flump.engine import YtDlpEngine
from flump.jobs import JobManager
from flump.platform import app_support_dir, read_clipboard
from flump.server import create_app
from flump.settings import SettingsStore


def find_port(preferred: int) -> int:
    start = preferred or 47321
    for port in range(start, start + 30):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError("No open port.")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="flump", description="Paste a page link and Flump saves the video.")
    parser.add_argument("urls", nargs="*", help="Links to save now")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args(argv)

    support = app_support_dir()
    settings = SettingsStore(support / "settings.json", support / "history.json")
    manager = JobManager(YtDlpEngine(), settings, clipboard_reader=read_clipboard)
    if args.urls:
        try:
            manager.submit_text("\n".join(args.urls))
        except ValueError as exc:
            print(exc, file=sys.stderr)
            raise SystemExit(2) from exc

    port = find_port(args.port)
    app = create_app(manager)
    url = f"http://127.0.0.1:{port}"
    folder = settings.snapshot()[0].download_dir
    print(f"Flump  {url}")
    print(f"Saving to  {folder}")
    print("Quit  Ctrl+C")

    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning", access_log=False)
    uvicorn.Server(config).run()


if __name__ == "__main__":
    main()
