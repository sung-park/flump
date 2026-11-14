import XCTest
@testable import FlumpCore

final class SupportTests: XCTestCase {
    func testExtractURLsStripsPunctuationAndDedupes() {
        let text = "see https://youtu.be/abc, and https://vimeo.com/1. again https://youtu.be/abc"
        XCTAssertEqual(extractURLs(text), ["https://youtu.be/abc", "https://vimeo.com/1"])
    }

    func testClipboardOnlyCountsBareURLs() {
        XCTAssertTrue(clipboardIsOnlyURLs("https://a.example/one\nhttps://b.example/two"))
        XCTAssertFalse(clipboardIsOnlyURLs("기사입니다 https://a.example/one 읽어 보세요"))
    }

    func testDurationAndErrors() {
        XCTAssertEqual(formatDuration(75), "1:15")
        XCTAssertEqual(formatDuration(3661), "1:01:01")
        XCTAssertEqual(humanizeError("ERROR: Unsupported URL: https://example.com"), "No video at this link.")
        XCTAssertTrue(humanizeError("Sign in to confirm you’re not a bot").contains("cookies"))
    }

    func testProgressLinesFromYtDlp() {
        let downloading = parseEngineLine("FLUMPROG downloading|  12.3%|  1.23MiB/s|00:08")
        XCTAssertEqual(downloading, .progress(phase: "downloading", percent: 12.3, speed: "1.23MiB/s", eta: "00:08"))
        let finished = parseEngineLine("FLUMPROG finished|100.0%|7.63MiB/s|NA")
        XCTAssertEqual(finished, .progress(phase: "processing", percent: 100, speed: "7.63MiB/s", eta: nil))
        XCTAssertEqual(parseEngineLine("FLUMPOST started"), .progress(phase: "processing", percent: nil, speed: nil, eta: nil))
        XCTAssertEqual(parseEngineLine("FLUMPFILE /tmp/ply/flower [flower].mp4"), .file("/tmp/ply/flower [flower].mp4"))
        XCTAssertEqual(parseEngineLine("ERROR: Unsupported URL: x"), .error("Unsupported URL: x"))
    }

    func testSingleVideoDoesNotPullAPlaylist() throws {
        let built = try downloadArguments(DownloadRequest(
            downloadDir: "/tmp/Flump",
            presetID: "best_mp4",
            subtitles: true,
            cookiesBrowser: "safari",
            playlistItems: nil,
            hasFFmpeg: true,
            ffmpegLocation: "/opt/homebrew/bin",
            jsRuntimes: ["node:/usr/local/bin/node"]
        ))
        XCTAssertNil(built.warning)
        XCTAssertTrue(built.arguments.contains("--no-playlist"))
        XCTAssertFalse(built.arguments.contains("--playlist-items"))
        XCTAssertTrue(built.arguments.contains("--merge-output-format"))
        XCTAssertTrue(built.arguments.contains("--cookies-from-browser"))
        XCTAssertTrue(built.arguments.contains("--write-subs"))
        XCTAssertTrue(built.arguments.contains("node:/usr/local/bin/node"))
    }

    func testPlaylistItemAndMissingFFmpeg() throws {
        let playlist = try downloadArguments(DownloadRequest(
            downloadDir: "/tmp/Flump",
            presetID: "720",
            subtitles: false,
            cookiesBrowser: "",
            playlistItems: "2",
            hasFFmpeg: true,
            ffmpegLocation: nil,
            jsRuntimes: []
        ))
        XCTAssertTrue(playlist.arguments.contains("--playlist-items"))
        XCTAssertFalse(playlist.arguments.contains("--no-playlist"))

        let fallback = try downloadArguments(DownloadRequest(
            downloadDir: "/tmp/Flump",
            presetID: "1080",
            subtitles: false,
            cookiesBrowser: "",
            playlistItems: nil,
            hasFFmpeg: false,
            ffmpegLocation: nil,
            jsRuntimes: []
        ))
        XCTAssertEqual(fallback.warning?.isEmpty, false)
        let formatIndex = try XCTUnwrap(fallback.arguments.firstIndex(of: "-f"))
        XCTAssertEqual(fallback.arguments[formatIndex + 1], "b[height<=1080]/b")
        XCTAssertFalse(fallback.arguments.contains("--merge-output-format"))

        XCTAssertThrowsError(try resolvePreset(id: "audio_mp3", hasFFmpeg: false))
    }

    func testProbeJSON() throws {
        let video = """
        {"_type":"video","title":"Me at the zoo","duration":19,"thumbnail":"https://i.example/t.jpg","extractor_key":"Youtube"}
        """.data(using: .utf8)!
        let parsed = try parseProbe(data: video, fallbackTitle: "url")
        XCTAssertEqual(parsed.kind, "video")
        XCTAssertEqual(parsed.title, "Me at the zoo")
        XCTAssertEqual(parsed.duration, "0:19")
        XCTAssertEqual(parsed.thumbnail, "https://i.example/t.jpg")

        let playlist = """
        {"_type":"playlist","title":"시리즈","extractor_key":"Youtube","playlist_count":2,"entries":[
          {"title":"하나","duration":60},
          null,
          {"title":"둘","duration":125}
        ]}
        """.data(using: .utf8)!
        let list = try parseProbe(data: playlist, fallbackTitle: "url")
        XCTAssertEqual(list.kind, "playlist")
        XCTAssertEqual(list.entries.map(\.title), ["하나", "둘"])
        XCTAssertEqual(list.entries.map(\.index), [1, 3])
        XCTAssertEqual(list.entries[1].duration, "2:05")
    }

    func testKVSDirectURLDecodesBase64AndPrefersHD() {
        let low = Data("https://cdn.example/get_file/1/a.mp4".utf8).base64EncodedString()
        let hd = Data("https://cdn.example/get_file/1/a_hd.mp4".utf8).base64EncodedString()
        let html = """
        var flashvars = {
          video_title: 'Sample clip',
          video_url: '\(low)',
          video_url_hd: '\(hd)',
        };
        kt_player('kt_player', 'player.swf', '100%', '100%', flashvars);
        """
        let media = kvsDirectURL(in: html)
        XCTAssertEqual(media?.url, "https://cdn.example/get_file/1/a_hd.mp4")
        XCTAssertEqual(media?.title, "Sample clip")
    }

    func testKVSIgnoresPlaceholderAndUnrelatedHTML() {
        let low = Data("https://cdn.example/get_file/1/a.mp4".utf8).base64EncodedString()
        let html = "var flashvars = { video_url: '\(low)', video_url_hd: 'MQ==' };"
        XCTAssertEqual(kvsDirectURL(in: html)?.url, "https://cdn.example/get_file/1/a.mp4")
        XCTAssertNil(kvsDirectURL(in: "<html>no player</html>"))
        XCTAssertEqual(
            humanizeError("ERROR: [generic] 1: No video formats found!"),
            "No video file on this page."
        )
    }

    func testRefererAndFileTitleArePassedThrough() throws {
        let built = try downloadArguments(DownloadRequest(
            downloadDir: "/tmp/Flump",
            presetID: "best_mp4",
            subtitles: false,
            cookiesBrowser: "",
            playlistItems: nil,
            hasFFmpeg: true,
            ffmpegLocation: nil,
            jsRuntimes: ["node:/usr/bin/node"],
            referer: "https://example.com/watch",
            fileTitle: "Sample 100%"
        ))
        XCTAssertTrue(built.arguments.contains("--referer"))
        XCTAssertTrue(built.arguments.contains("https://example.com/watch"))
        let output = try XCTUnwrap(built.arguments.firstIndex(of: "-o"))
        XCTAssertEqual(built.arguments[output + 1], "Sample 100 [%(id)s].%(ext)s")
        let probe = probeArguments(jsRuntimes: [], referer: "https://example.com/watch")
        XCTAssertTrue(probe.contains("--referer"))
    }
}
