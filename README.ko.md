# Flump

Flump는 Mac용 무료 오픈 소스 [yt-dlp](https://github.com/yt-dlp/yt-dlp) 프론트엔드입니다. Downie 대신 쓸 수 있습니다. 페이지 링크를 붙여 넣으면 MP4나 MP3로 저장합니다. YouTube, Vimeo, X와 yt-dlp가 지원하는 다른 사이트가 해당됩니다. SwiftUI 앱이고, macOS 14 이상, Apple Silicon, MIT 라이선스입니다.

자세한 설명은 [README.md](README.md)에 있습니다. 앱은 [GitHub Release](https://github.com/sung-park/flump/releases/latest)에 있습니다.

링크는 이 Mac 안에만 있습니다. 받은 파일은 `~/Downloads/Flump`에 저장됩니다.

ffmpeg가 없으면 YouTube 영상은 낮은 화질로 저장됩니다. 앱의 **Get ffmpeg**가 Application Support에 ffmpeg를 받습니다. YouTube는 JavaScript 런타임도 필요해서, 없을 때는 **Get Deno**를 누르면 됩니다. 번들에 들어 있는 yt-dlp는 첫 실행 때 Application Support로 복사되고, 그다음부터는 stable 채널로 스스로 갱신됩니다.

저장할 권리가 있는 영상만 받으세요.
