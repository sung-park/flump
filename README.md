# Flump

Flump is a free, open-source [yt-dlp](https://github.com/yt-dlp/yt-dlp) front-end for Mac, and a Downie alternative. Paste a page link — YouTube, Vimeo, X, and the other sites yt-dlp supports — and save MP4 or MP3. Native SwiftUI app. macOS 14 or later. Apple Silicon. MIT License.

The link stays on your machine. A small creature, a link, and a file that lands in your Downloads folder.

![Flump](assets/window.png)

## Download

The Mac app is on the [GitHub release](https://github.com/sung-park/flump/releases/latest):

- [Flump-0.1.2-macos-arm64.zip](https://github.com/sung-park/flump/releases/download/v0.1.2/Flump-0.1.2-macos-arm64.zip)

Unzip it and open `Flump.app`. The build is ad-hoc signed, so the first time macOS may refuse it. Right-click the app, choose Open, or run:

```bash
xattr -cr Flump.app
```

macOS 14 or later. Apple Silicon only.

yt-dlp ships inside the app and copies itself to `~/Library/Application Support/Flump/bin` on first launch, then updates itself from the stable channel. ffmpeg and a JavaScript runtime (Deno) are separate. Without ffmpeg, YouTube saves stay at a low resolution, because YouTube keeps picture and sound apart. The app can download both tools into Application Support. You can also install them yourself:

```bash
brew install ffmpeg
```

Saved files go to `~/Downloads/Flump`. Settings and history go to `~/Library/Application Support/Flump`.

## How do I download a video on a Mac?

Open Flump, paste the page link, and press Save. One link, several links, or a sentence that contains a link all work. You can also drop a link on the window. Flump asks yt-dlp for the video and writes the file to `~/Downloads/Flump`.

## Does Flump need ffmpeg?

Higher resolutions need ffmpeg, because the picture and the sound arrive as two files and have to be joined. Without ffmpeg, Flump saves one file that already contains both, which on YouTube is a much lower resolution. Audio-only saves need ffmpeg too. Choose **Get ffmpeg** in the app, or run `brew install ffmpeg`. The copy Flump downloads is GPL software from [osxexperts.net](https://www.osxexperts.net/) and stays on this Mac. The checksum is pinned. If that file name changes, Flump tries the same zip on the [v0.1.1 release](https://github.com/sung-park/flump/releases/download/v0.1.1/ffmpeg902arm.zip).

YouTube also needs a JavaScript runtime. Choose **Get Deno**, or install Node or Deno yourself.

## Flump vs Downie vs the yt-dlp command

| | Flump | Downie | yt-dlp |
| --- | --- | --- | --- |
| Price | Free, MIT | Paid | Free |
| How you use it | Mac window | Mac window | Terminal |
| Engine | yt-dlp | — | yt-dlp |
| Updates to the engine | The app updates its own yt-dlp | App updates | You update the command |

Flump is the window. yt-dlp is the part that understands each site.

## What it does

- Paste one link, many links, or a sentence that contains links. Drop a link on the window.
- Best MP4, best quality, 1080p, 720p, or audio only (M4A, MP3).
- Up to three saves at once. Looking up a page does not block a save that is already waiting.
- Progress, speed, time left, cancel, and try again.
- A playlist opens a list so you can save the ones you want.
- Subtitles, when the page has them.
- Pick the save folder, then reveal the file in Finder.
- Optional cookies from Safari, Chrome, Whale, Firefox, Edge, or Brave. They stay on this Mac.
- Optional clipboard watch, only when the clipboard is nothing but links.

## Build from source

```bash
./scripts/build-app.sh
open dist/Flump.app
```

The script runs the tests, builds the app, downloads yt-dlp 2026.10.26, checks it against the release SHA-256, and writes a zip under `release/`. Git ignores that zip. The copy people download is the GitHub release.

There is also a local browser UI, if you want it:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
python -m flump
```

## Development

Flump passes `--js-runtimes` only when it has found Node or Deno. A bare `--js-runtimes node` does nothing if Node is not installed.

```bash
cd macos && swift test
pip install -e '.[dev]'
pytest
```

## Credits

Site support comes from yt-dlp. Flump does not upload the link or the file.

Only save videos you have the right to save. Follow each site's terms and the copyright on the video.

MIT License. Korean notes are in [README.ko.md](README.ko.md).
