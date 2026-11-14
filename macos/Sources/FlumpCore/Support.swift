import Foundation

public struct Preset: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let format: String
    public let merge: String?
    public let audio: String?
    public let needsFFmpeg: Bool

    public init(id: String, label: String, format: String, merge: String?, audio: String?, needsFFmpeg: Bool) {
        self.id = id
        self.label = label
        self.format = format
        self.merge = merge
        self.audio = audio
        self.needsFFmpeg = needsFFmpeg
    }
}

public let presets: [Preset] = [
    Preset(id: "best_mp4", label: "Best MP4", format: "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b", merge: "mp4", audio: nil, needsFFmpeg: true),
    Preset(id: "best", label: "Best", format: "bv*+ba/b", merge: nil, audio: nil, needsFFmpeg: true),
    Preset(id: "1080", label: "1080p", format: "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b", merge: "mp4", audio: nil, needsFFmpeg: true),
    Preset(id: "720", label: "720p", format: "bv*[height<=720]+ba/b[height<=720]/bv*+ba/b", merge: "mp4", audio: nil, needsFFmpeg: true),
    Preset(id: "audio_m4a", label: "Audio M4A", format: "ba[ext=m4a]/ba/b", merge: nil, audio: "m4a", needsFFmpeg: true),
    Preset(id: "audio_mp3", label: "Audio MP3", format: "ba/b", merge: nil, audio: "mp3", needsFFmpeg: true),
]

private let singleFileFallback = [
    "best_mp4": "b",
    "best": "b",
    "1080": "b[height<=1080]/b",
    "720": "b[height<=720]/b",
]

public struct PresetError: Error, Equatable, Sendable {
    public let message: String
}

public func resolvePreset(id: String, hasFFmpeg: Bool) throws -> (preset: Preset, warning: String?) {
    guard let preset = presets.first(where: { $0.id == id }) else {
        throw PresetError(message: "Unknown quality.")
    }
    if !preset.needsFFmpeg || hasFFmpeg {
        return (preset, nil)
    }
    if preset.audio != nil {
        throw PresetError(message: "Audio-only downloads need ffmpeg. Run brew install ffmpeg.")
    }
    let fallback = Preset(
        id: preset.id,
        label: preset.label,
        format: singleFileFallback[preset.id] ?? "b",
        merge: nil,
        audio: nil,
        needsFFmpeg: false
    )
    return (fallback, "ffmpeg isn't installed, so Flump saves a file that already has picture and sound together.")
}

public struct DownloadRequest: Equatable, Sendable {
    public var downloadDir: String
    public var presetID: String
    public var subtitles: Bool
    public var cookiesBrowser: String
    public var playlistItems: String?
    public var hasFFmpeg: Bool
    public var ffmpegLocation: String?
    public var jsRuntimes: [String]
    public var referer: String?
    public var fileTitle: String?

    public init(
        downloadDir: String,
        presetID: String,
        subtitles: Bool,
        cookiesBrowser: String,
        playlistItems: String?,
        hasFFmpeg: Bool,
        ffmpegLocation: String?,
        jsRuntimes: [String],
        referer: String? = nil,
        fileTitle: String? = nil
    ) {
        self.downloadDir = downloadDir
        self.presetID = presetID
        self.subtitles = subtitles
        self.cookiesBrowser = cookiesBrowser
        self.playlistItems = playlistItems
        self.hasFFmpeg = hasFFmpeg
        self.ffmpegLocation = ffmpegLocation
        self.jsRuntimes = jsRuntimes
        self.referer = referer
        self.fileTitle = fileTitle
    }
}

public func downloadArguments(_ request: DownloadRequest) throws -> (arguments: [String], warning: String?) {
    let resolved = try resolvePreset(id: request.presetID, hasFFmpeg: request.hasFFmpeg)
    var args = commonArguments(jsRuntimes: request.jsRuntimes)
    args += [
        "--newline",
        "--no-simulate",
        "--progress",
        "--progress-template", "download:FLUMPROG %(progress.status)s|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
        "--progress-template", "postprocess:FLUMPOST %(progress.status)s",
        "--print", "after_move:FLUMPFILE %(filepath)s",
        "--retries", "10",
        "--fragment-retries", "10",
        "--concurrent-fragments", "4",
        "-P", request.downloadDir,
        "-o", outputTemplate(fileTitle: request.fileTitle),
        "-f", resolved.preset.format,
    ]
    if let merge = resolved.preset.merge {
        args += ["--merge-output-format", merge]
    }
    if let audio = resolved.preset.audio {
        args += ["-x", "--audio-format", audio, "--audio-quality", "0"]
    }
    if let playlistItems = request.playlistItems {
        args += ["--playlist-items", playlistItems]
    } else {
        args.append("--no-playlist")
    }
    if request.subtitles && resolved.preset.audio == nil {
        args += ["--write-subs", "--write-auto-subs", "--convert-subs", "srt", "--sub-langs", "ko,ko-KR,en"]
    }
    if !request.cookiesBrowser.isEmpty {
        args += ["--cookies-from-browser", request.cookiesBrowser]
    }
    if let ffmpegLocation = request.ffmpegLocation {
        args += ["--ffmpeg-location", ffmpegLocation]
    }
    if let referer = request.referer, !referer.isEmpty {
        args += ["--referer", referer]
    }
    return (args, resolved.warning)
}

public func probeArguments(jsRuntimes: [String], referer: String? = nil) -> [String] {
    var args = commonArguments(jsRuntimes: jsRuntimes)
    if let referer, !referer.isEmpty {
        args += ["--referer", referer]
    }
    args += ["-J", "--flat-playlist", "--playlist-end", "100", "--no-playlist"]
    return args
}

private func outputTemplate(fileTitle: String?) -> String {
    guard let fileTitle else { return "%(title).180B [%(id)s].%(ext)s" }
    let stem = sanitizeFileTitle(fileTitle)
    guard !stem.isEmpty else { return "%(title).180B [%(id)s].%(ext)s" }
    return "\(stem) [%(id)s].%(ext)s"
}

private func sanitizeFileTitle(_ title: String) -> String {
    let banned = CharacterSet(charactersIn: "%/\\:\n\r\"")
    var text = String(title.unicodeScalars.map { banned.contains($0) ? " " : Character($0) })
    while text.contains("  ") {
        text = text.replacingOccurrences(of: "  ", with: " ")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.count > 180 {
        text = String(text.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}

private func commonArguments(jsRuntimes: [String]) -> [String] {
    var args = ["--no-colors", "--no-warnings"]
    for runtime in jsRuntimes where !runtime.isEmpty {
        args += ["--js-runtimes", runtime]
    }
    return args
}

public func extractURLs(_ text: String, limit: Int = 30) -> [String] {
    guard !text.isEmpty else { return [] }
    guard let expression = try? NSRegularExpression(pattern: "https?://[^\\s<>\"'`]+", options: [.caseInsensitive]) else {
        return []
    }
    let range = NSRange(text.startIndex..., in: text)
    var found: [String] = []
    var seen = Set<String>()
    for match in expression.matches(in: text, range: range) {
        guard let swiftRange = Range(match.range, in: text) else { continue }
        var url = String(text[swiftRange])
        while let last = url.last, ".,;:)]}>\"'`".contains(last) {
            url.removeLast()
        }
        guard url.count >= 8, seen.insert(url).inserted else { continue }
        found.append(url)
        if found.count >= limit { break }
    }
    return found
}

public struct DirectMedia: Equatable, Sendable {
    public var url: String
    public var title: String?

    public init(url: String, title: String?) {
        self.url = url
        self.title = title
    }
}

/// Some players hide the file address in base64 `flashvars.video_url`. yt-dlp
/// only keeps values that already contain `/get_file/`, so decode it here.
public func kvsDirectURL(in html: String) -> DirectMedia? {
    let lowered = html.lowercased()
    guard lowered.contains("flashvars") || lowered.contains("kt_player") else { return nil }
    guard let expression = try? NSRegularExpression(
        pattern: #"(video_(?:url(?:_hd)?|alt_url\d*))\s*:\s*['"]([^'"]+)['"]"#,
        options: [.caseInsensitive]
    ) else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    var bestRank = -1
    var bestURL: String?
    for match in expression.matches(in: html, range: range) {
        guard match.numberOfRanges >= 3,
              let keyRange = Range(match.range(at: 1), in: html),
              let valueRange = Range(match.range(at: 2), in: html) else { continue }
        let key = html[keyRange].lowercased()
        guard let url = decodeMediaToken(String(html[valueRange])) else { continue }
        let rank = key.contains("_hd") ? 2 : (key.contains("alt_") ? 1 : 0)
        if rank > bestRank {
            bestRank = rank
            bestURL = url
        }
    }
    guard let bestURL else { return nil }
    return DirectMedia(url: bestURL, title: kvsTitle(in: html))
}

private func decodeMediaToken(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
    var padded = trimmed
    let remainder = padded.count % 4
    if remainder != 0 {
        padded += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: padded),
          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          text.hasPrefix("http://") || text.hasPrefix("https://") else {
        return nil
    }
    return text
}

private func kvsTitle(in html: String) -> String? {
    guard let expression = try? NSRegularExpression(
        pattern: #"video_title\s*:\s*'([^']*)'"#,
        options: [.caseInsensitive]
    ),
          let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
          let range = Range(match.range(at: 1), in: html) else { return nil }
    var title = String(html[range])
        .replacingOccurrences(of: "\\'", with: "'")
        .replacingOccurrences(of: "\\/", with: "/")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty { return nil }
    if title.count > 300 { title = String(title.prefix(300)) }
    return title
}

public func clipboardIsOnlyURLs(_ text: String) -> Bool {
    let urls = extractURLs(text)
    guard !urls.isEmpty else { return false }
    var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for url in urls {
        remainder = remainder.replacingOccurrences(of: url, with: "")
    }
    return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

public func formatDuration(_ seconds: Double) -> String? {
    guard seconds >= 0, seconds.isFinite else { return nil }
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

public func humanizeError(_ message: String) -> String {
    let low = cleanMessage(message).lowercased()
    if low.isEmpty { return "Couldn't save that." }
    if low.contains("no video formats") || low.contains("no formats found") {
        return "No video file on this page."
    }
    if low.contains("unsupported url") || low.contains("no suitable extractor") || low.contains("unable to extract") {
        return "No video at this link."
    }
    if low.contains("private") { return "This video is private." }
    if low.contains("sign in to confirm") || low.contains("not a bot") {
        return "The site wants to check that you're a person. Turn on browser cookies in Settings."
    }
    if low.contains("sign in") || low.contains("login") {
        return "This video needs a login. Turn on browser cookies in Settings."
    }
    if low.contains("ffmpeg") || low.contains("merging of multiple formats") {
        return "ffmpeg is required. Choose Get ffmpeg, or run brew install ffmpeg."
    }
    if low.contains("javascript runtime") || low.contains("js runtime") {
        return "YouTube needs a JavaScript runtime. Choose Get Deno."
    }
    if low.contains("not available in your country") || low.contains("geo") {
        return "This video isn't available in your region."
    }
    if low.contains("removed") || low.contains("deleted") || low.contains("unavailable") {
        return "This video is unavailable. It may have been removed."
    }
    if low.contains("no space") || low.contains("disk") {
        return "Not enough disk space."
    }
    if low.contains("timed out") || low.contains("network") || low.contains("connection") {
        return "The download failed because of a network problem."
    }
    if low.contains("requested format is not available") {
        return "That quality isn't available. Pick another one in Settings."
    }
    return "Couldn't save that."
}

public func cleanMessage(_ message: String) -> String {
    var text = message.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    if let range = text.range(of: "ERROR:") {
        text = String(text[range.upperBound...])
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum EngineEvent: Equatable, Sendable {
    case progress(phase: String, percent: Double?, speed: String?, eta: String?)
    case file(String)
    case error(String)
}

public func parseEngineLine(_ line: String) -> EngineEvent? {
    if line.hasPrefix("FLUMPROG ") {
        let parts = line.dropFirst("FLUMPROG ".count).split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let status = parts.first, !status.isEmpty else { return nil }
        let percent = parts.count > 1 ? parsePercent(parts[1]) : nil
        let speed = parts.count > 2 ? blankToNil(parts[2]) : nil
        let eta = parts.count > 3 ? blankToNil(parts[3]) : nil
        if status == "finished" {
            return .progress(phase: "processing", percent: percent ?? 100, speed: speed, eta: nil)
        }
        return .progress(phase: "downloading", percent: percent, speed: speed, eta: eta)
    }
    if line.hasPrefix("FLUMPOST") {
        return .progress(phase: "processing", percent: nil, speed: nil, eta: nil)
    }
    if line.hasPrefix("FLUMPFILE ") {
        let path = line.dropFirst("FLUMPFILE ".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return .file(path)
    }
    if line.contains("ERROR:") {
        let detail = cleanMessage(line)
        guard !detail.isEmpty else { return nil }
        return .error(detail)
    }
    return nil
}

private func parsePercent(_ text: String) -> Double? {
    let cleaned = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
    return Double(cleaned)
}

private func blankToNil(_ text: String) -> String? {
    if text.isEmpty || text == "NA" || text == "Unknown" { return nil }
    return text
}

public struct ProbeEntry: Equatable, Sendable {
    public let index: Int
    public let title: String
    public let duration: String?
}

public struct ProbeResult: Equatable, Sendable {
    public var kind: String
    public var title: String
    public var extractor: String?
    public var thumbnail: String?
    public var duration: String?
    public var entries: [ProbeEntry]
    public var truncated: Bool
    public var playlistItems: String?
}

public func parseProbe(data: Data, fallbackTitle: String) throws -> ProbeResult {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let info = object as? [String: Any] else {
        throw PresetError(message: "No video at this link.")
    }
    if (info["_type"] as? String) == "playlist" {
        return playlistResult(info, fallbackTitle: fallbackTitle)
    }
    return ProbeResult(
        kind: "video",
        title: title(from: info, fallback: fallbackTitle),
        extractor: extractor(from: info),
        thumbnail: thumbnail(from: info),
        duration: duration(from: info),
        entries: [],
        truncated: false,
        playlistItems: nil
    )
}

private func playlistResult(_ info: [String: Any], fallbackTitle: String) -> ProbeResult {
    let raw = info["entries"] as? [Any] ?? []
    var entries: [ProbeEntry] = []
    for (offset, item) in raw.enumerated() {
        guard let entry = item as? [String: Any] else { continue }
        entries.append(ProbeEntry(
            index: offset + 1,
            title: title(from: entry, fallback: "Item \(offset + 1)"),
            duration: duration(from: entry)
        ))
    }
    let count = (info["playlist_count"] as? NSNumber)?.intValue ?? (info["n_entries"] as? NSNumber)?.intValue
    let truncated = (count ?? 0) > entries.count || entries.count >= 100
    if entries.count == 1 && !truncated {
        let only = entries[0]
        return ProbeResult(
            kind: "video",
            title: only.title,
            extractor: extractor(from: info),
            thumbnail: thumbnail(from: info),
            duration: only.duration,
            entries: [],
            truncated: false,
            playlistItems: String(only.index)
        )
    }
    if entries.isEmpty {
        return ProbeResult(
            kind: "empty",
            title: fallbackTitle,
            extractor: extractor(from: info),
            thumbnail: nil,
            duration: nil,
            entries: [],
            truncated: false,
            playlistItems: nil
        )
    }
    return ProbeResult(
        kind: "playlist",
        title: title(from: info, fallback: fallbackTitle),
        extractor: extractor(from: info),
        thumbnail: thumbnail(from: info),
        duration: nil,
        entries: entries,
        truncated: truncated,
        playlistItems: nil
    )
}

private func title(from info: [String: Any], fallback: String) -> String {
    let raw = (info["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (raw?.isEmpty == false ? raw! : fallback)
    return String(value.prefix(300))
}

private func extractor(from info: [String: Any]) -> String? {
    (info["extractor_key"] as? String) ?? (info["extractor"] as? String)
}

private func thumbnail(from info: [String: Any]) -> String? {
    if let url = info["thumbnail"] as? String, url.hasPrefix("http://") || url.hasPrefix("https://") {
        return url
    }
    let thumbs = info["thumbnails"] as? [[String: Any]] ?? []
    for item in thumbs.reversed() {
        if let url = item["url"] as? String, url.hasPrefix("http://") || url.hasPrefix("https://") {
            return url
        }
    }
    return nil
}

private func duration(from info: [String: Any]) -> String? {
    guard let number = info["duration"] as? NSNumber else { return nil }
    return formatDuration(number.doubleValue)
}

public func locateTool(_ name: String, binDirectory: URL? = nil, path: String? = nil) -> String? {
    let managed = (binDirectory ?? flumpBinDirectory()).appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: managed) {
        return managed
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "\(home)/.local/bin/\(name)",
        "/usr/bin/\(name)",
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return which(name, path: path ?? extendedPath())
}

public func extendedPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
        flumpBinDirectory().path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(home)/.local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")
}

public func which(_ name: String, path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    process.environment = ["PATH": path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let found = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let found, !found.isEmpty else { return nil }
    return found
}

public func makeID() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
}
