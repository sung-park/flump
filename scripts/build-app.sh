#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="0.1.2"
build_number="3"
cd "$root/macos"
swift test
swift build -c release
bin="$(swift build -c release --show-bin-path)"

app="$root/dist/Flump.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Flump" "$app/Contents/MacOS/Flump"
chmod +x "$app/Contents/MacOS/Flump"
cp -R "$bin/Flump_FlumpCore.bundle" "$app/Contents/Resources/Flump_FlumpCore.bundle"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Flump</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>app.flump.macos</string>
  <key>CFBundleDisplayName</key>
  <string>Flump</string>
  <key>CFBundleName</key>
  <string>Flump</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${build_number}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

icon_src="$(mktemp -d)"
cp "$root/assets/AppIcon.png" "$icon_src/icon-1024.png"
iconset="$icon_src/AppIcon.iconset"
mkdir -p "$iconset"
sips -z 16 16 "$icon_src/icon-1024.png" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_src/icon-1024.png" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_src/icon-1024.png" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_src/icon-1024.png" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_src/icon-1024.png" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_src/icon-1024.png" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_src/icon-1024.png" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_src/icon-1024.png" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_src/icon-1024.png" --out "$iconset/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_src/icon-1024.png" --out "$iconset/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

pin="$root/macos/Sources/FlumpCore/PinnedTools.json"
url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["yt-dlp"]["url"])' "$pin")"
sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["yt-dlp"]["sha256"])' "$pin")"
binary="$app/Contents/Resources/yt-dlp"
curl -fsSL -o "$binary" "$url"
echo "$sha  $binary" | shasum -a 256 -c -
if file "$binary" | grep -q -i "zip"; then
  unzip -o "$binary" -d "$icon_src/ytdlp"
  found="$(find "$icon_src/ytdlp" -type f -name 'yt-dlp*' | head -n 1)"
  mv "$found" "$binary"
fi
chmod +x "$binary"
xattr -cr "$app" || true
codesign --force --deep --sign - "$app"
mkdir -p "$root/release"
archive="$root/release/Flump-${version}-macos-arm64.zip"
ditto -c -k --keepParent "$app" "$archive"
shasum -a 256 "$archive" > "${archive}.sha256"
echo "built $app"
