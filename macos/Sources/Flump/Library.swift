import AppKit
import Foundation
import FlumpCore

struct Settings: Equatable {
    var downloadDir: String
    var preset: String = "best_mp4"
    var subtitles: Bool = false
    var clipboardWatch: Bool = false
    var concurrent: Int = 2
    var cookiesBrowser: String = ""
}

struct MediaJob: Identifiable, Equatable {
    var id: String
    var url: String
    var title: String
    var status: String
    var kind: String = "video"
    var thumbnail: String?
    var extractor: String?
    var duration: String?
    var percent: Double?
    var speed: String?
    var eta: String?
    var filepath: String?
    var error: String?
    var errorDetail: String?
    var warning: String?
    var entries: [ProbeEntry] = []
    var truncated: Bool = false
    var playlistItems: String?
    var directURL: String?
    var referer: String?
    var fileTitle: String?
    var source: String = "paste"
    var createdAt: Double = Date().timeIntervalSince1970

    var isActive: Bool {
        ["queued", "extracting", "downloading", "processing"].contains(status)
    }
}

private enum Work {
    case probe(String)
    case download(String)
}

@MainActor
final class Library: ObservableObject {
    @Published var jobs: [MediaJob] = []
    @Published var history: [MediaJob] = []
    @Published var settings: Settings
    @Published var selection: [String: Set<Int>] = [:]
    @Published var alert: String?
    @Published var ytDlpPath: String?
    @Published var ffmpegPath: String?
    @Published var jsRuntime: String?

    private var queue: [Work] = []
    private var draining = false
    private var active = 0
    private var sessions: [String: YtDlpSession] = [:]
    private var cancelled: Set<String> = []
    private var recent: [String: Date] = [:]
    private var lastClipboardChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let supportURL: URL
    private let settingsURL: URL
    private let historyURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flump", isDirectory: true)
        supportURL = base
        settingsURL = base.appendingPathComponent("settings.json")
        historyURL = base.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Flump", isDirectory: true)
        settings = Self.loadSettings(from: settingsURL, fallback: downloads.path)
        try? FileManager.default.createDirectory(atPath: settings.downloadDir, withIntermediateDirectories: true)
        history = Self.loadHistory(from: historyURL)
        refreshTools()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
    }

    func refreshTools() {
        let bundle = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp").path
        ytDlpPath = locateTool("yt-dlp", bundlePath: bundle)
        ffmpegPath = locateTool("ffmpeg")
        if let node = locateTool("node") {
            jsRuntime = node
        } else if let deno = locateTool("deno") {
            jsRuntime = deno
        } else {
            jsRuntime = nil
        }
    }

    func submit(text: String, source: String = "paste") {
        let urls = extractURLs(text)
        guard !urls.isEmpty else {
            alert = "No link found."
            return
        }
        guard ytDlpPath != nil else {
            alert = "yt-dlp is missing. Run brew install yt-dlp."
            return
        }
        for url in urls {
            enqueue(url: url, title: url, playlistItems: nil, source: source, known: false)
        }
    }

    func downloadEntries(jobID: String, indexes: [Int]?) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.kind == "playlist" else { return }
        let chosen: [ProbeEntry]
        if let indexes {
            let wanted = Set(indexes)
            chosen = job.entries.filter { wanted.contains($0.index) }
        } else {
            chosen = job.entries
        }
        guard !chosen.isEmpty else {
            alert = "Choose a video to save."
            return
        }
        jobs.removeAll { $0.id == jobID }
        selection[jobID] = nil
        for entry in chosen {
            enqueue(url: job.url, title: entry.title, duration: entry.duration, playlistItems: String(entry.index), source: "paste", known: true)
        }
    }

    func cancel(id: String) {
        cancelled.insert(id)
        sessions[id]?.cancel()
        queue.removeAll { workID($0) == id }
        update(id) { job in
            if job.isActive || job.status == "review" || job.status == "queued" {
                job.status = "cancelled"
                job.error = nil
            }
        }
    }

    func dismiss(id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if job.isActive {
            alert = "Cancel the download before removing it."
            return
        }
        jobs.removeAll { $0.id == id }
        selection[id] = nil
    }

    func retry(id: String) {
        let job = jobs.first { $0.id == id } ?? history.first { $0.id == id }
        guard let job else { return }
        enqueue(
            url: job.url,
            title: job.title,
            duration: job.duration,
            playlistItems: job.playlistItems,
            source: "paste",
            known: job.playlistItems != nil
        )
    }

    func reveal(id: String) {
        guard let path = filepath(id), FileManager.default.fileExists(atPath: path) else {
            alert = "The file isn't in the folder."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFile(id: String) {
        guard let path = filepath(id), FileManager.default.fileExists(atPath: path) else {
            alert = "The file isn't in the folder."
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openDownloadFolder() {
        let url = URL(fileURLWithPath: settings.downloadDir)
        NSWorkspace.shared.open(url)
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder for videos"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDownloadDir(url.path)
    }

    func setDownloadDir(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        if URL(fileURLWithPath: expanded).path == "/" {
            alert = "Can't save to that folder."
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
        } catch {
            alert = "Can't write to that folder."
            return
        }
        settings.downloadDir = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        saveSettings()
    }

    func saveSettings() {
        settings.concurrent = min(3, max(1, settings.concurrent))
        if !presets.contains(where: { $0.id == settings.preset }) {
            settings.preset = "best_mp4"
        }
        let payload: [String: Any] = [
            "download_dir": settings.downloadDir,
            "preset": settings.preset,
            "subtitles": settings.subtitles,
            "clipboard_watch": settings.clipboardWatch,
            "concurrent": settings.concurrent,
            "cookies_browser": settings.cookiesBrowser,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsURL)
        }
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    func dropHistory(id: String) {
        history.removeAll { $0.id == id }
        persistHistory()
    }

    func setIncluded(_ jobID: String, index: Int, on: Bool) {
        var set = selection[jobID] ?? []
        if on { set.insert(index) } else { set.remove(index) }
        selection[jobID] = set
    }

    func setAll(_ jobID: String, on: Bool, indexes: [Int]) {
        selection[jobID] = on ? Set(indexes) : []
    }

    private func enqueue(url: String, title: String, duration: String? = nil, playlistItems: String?, source: String, known: Bool) {
        let job = MediaJob(
            id: makeID(),
            url: url,
            title: title,
            status: known ? "queued" : "extracting",
            duration: duration,
            playlistItems: playlistItems,
            source: source
        )
        jobs.append(job)
        recent[url] = Date()
        queue.append(known ? .download(job.id) : .probe(job.id))
        pump()
    }

    private func pump() {
        if draining { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while active < settings.concurrent, !queue.isEmpty {
            let work = queue.removeFirst()
            let id = workID(work)
            if cancelled.contains(id) { continue }
            active += 1
            await perform(work)
            active -= 1
        }
        draining = false
        if !queue.isEmpty { pump() }
    }

    private func perform(_ work: Work) async {
        switch work {
        case .probe(let id):
            await probe(id)
        case .download(let id):
            await download(id)
        }
    }

    private func probe(_ id: String, allowFallback: Bool = true) async {
        guard let binary = ytDlpPath, let job = jobs.first(where: { $0.id == id }) else { return }
        if cancelled.contains(id) {
            update(id) { $0.status = "cancelled" }
            return
        }
        update(id) { $0.status = "extracting" }
        let target = job.directURL ?? job.url
        let session: YtDlpSession
        do {
            session = try YtDlpSession(
                binary: binary,
                arguments: probeArguments(jsRuntimes: runtimeArgs(), referer: job.referer) + [target],
                environment: ["PATH": extendedPath()]
            )
        } catch {
            fail(id, detail: error.localizedDescription)
            return
        }
        sessions[id] = session
        var jsonLine = ""
        for await line in session.lines {
            if case .stdout(let text) = line, text.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                jsonLine = text
            }
        }
        let code = await session.exitCode()
        sessions[id] = nil
        if cancelled.contains(id) {
            update(id) { $0.status = "cancelled" }
            return
        }
        let snapshot = session.snapshot()
        guard code == 0, let data = jsonLine.data(using: .utf8), !data.isEmpty else {
            let detail = snapshot.error ?? "No video at this link."
            if allowFallback, await applyKVSFallback(id, detail: detail) {
                await probe(id, allowFallback: false)
                return
            }
            fail(id, detail: detail)
            return
        }
        do {
            let result = try parseProbe(data: data, fallbackTitle: job.url)
            if result.kind == "empty" {
                fail(id, detail: "No video at this link.")
                return
            }
            if result.kind == "playlist" {
                update(id) { job in
                    job.kind = "playlist"
                    job.status = "review"
                    job.title = result.title
                    job.extractor = result.extractor
                    job.thumbnail = result.thumbnail
                    job.entries = result.entries
                    job.truncated = result.truncated
                }
                selection[id] = Set(result.entries.map(\.index))
                return
            }
            update(id) { job in
                let keepTitle = job.title != job.url && !job.title.isEmpty
                if !keepTitle { job.title = result.title }
                job.extractor = result.extractor
                job.thumbnail = result.thumbnail
                job.duration = result.duration
                if let items = result.playlistItems, job.playlistItems == nil {
                    job.playlistItems = items
                }
                job.status = "queued"
            }
            queue.append(.download(id))
        } catch {
            fail(id, detail: error.localizedDescription)
        }
    }

    private func applyKVSFallback(_ id: String, detail: String) async -> Bool {
        guard let job = jobs.first(where: { $0.id == id }), job.directURL == nil else { return false }
        let low = detail.lowercased()
        guard low.contains("no video formats") || low.contains("unsupported url") || low.contains("unable to extract") else {
            return false
        }
        guard let html = await fetchPage(job.url), let media = kvsDirectURL(in: html) else { return false }
        update(id) { job in
            job.directURL = media.url
            job.referer = job.url
            if let title = media.title, !title.isEmpty {
                job.title = title
                job.fileTitle = title
            }
        }
        return true
    }

    private func fetchPage(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func download(_ id: String) async {
        guard let binary = ytDlpPath, let job = jobs.first(where: { $0.id == id }) else { return }
        if cancelled.contains(id) {
            update(id) { $0.status = "cancelled" }
            return
        }
        let request = DownloadRequest(
            downloadDir: settings.downloadDir,
            presetID: settings.preset,
            subtitles: settings.subtitles,
            cookiesBrowser: settings.cookiesBrowser,
            playlistItems: job.playlistItems,
            hasFFmpeg: ffmpegPath != nil,
            ffmpegLocation: ffmpegPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
            jsRuntimes: runtimeArgs(),
            referer: job.referer,
            fileTitle: job.fileTitle
        )
        let built: (arguments: [String], warning: String?)
        do {
            built = try downloadArguments(request)
        } catch let error as PresetError {
            fail(id, detail: error.message)
            return
        } catch {
            fail(id, detail: error.localizedDescription)
            return
        }
        update(id) { job in
            job.status = "downloading"
            job.warning = built.warning
        }
        let session: YtDlpSession
        do {
            session = try YtDlpSession(
                binary: binary,
                arguments: built.arguments + [job.directURL ?? job.url],
                environment: ["PATH": extendedPath()]
            )
        } catch {
            fail(id, detail: error.localizedDescription)
            return
        }
        sessions[id] = session
        for await line in session.lines {
            let text: String
            switch line {
            case .stdout(let value), .stderr(let value): text = value
            }
            guard let event = parseEngineLine(text) else { continue }
            update(id) { job in
                switch event {
                case .progress(let phase, let percent, let speed, let eta):
                    job.status = phase
                    if let percent { job.percent = percent }
                    if let speed { job.speed = speed }
                    if let eta { job.eta = eta }
                case .file(let path):
                    job.filepath = path
                case .error(let detail):
                    job.errorDetail = detail
                }
            }
        }
        let code = await session.exitCode()
        let snapshot = session.snapshot()
        sessions[id] = nil
        if cancelled.contains(id) {
            update(id) { $0.status = "cancelled" }
            return
        }
        let path = snapshot.file ?? jobs.first { $0.id == id }?.filepath
        if code == 0, let path, FileManager.default.fileExists(atPath: path) {
            update(id) { job in
                job.status = "done"
                job.filepath = path
                job.percent = 100
                job.error = nil
            }
            if let finished = jobs.first(where: { $0.id == id }) {
                jobs.removeAll { $0.id == id }
                history.insert(finished, at: 0)
                if history.count > 200 { history.removeLast(history.count - 200) }
                persistHistory()
            }
            return
        }
        fail(id, detail: snapshot.error ?? jobs.first { $0.id == id }?.errorDetail ?? "The file wasn't saved.")
    }

    private func fail(_ id: String, detail: String) {
        let message = humanizeError(detail)
        let shown = (message == "Couldn't save that." && detail.count < 180) ? detail : message
        update(id) { job in
            guard job.status != "cancelled" else { return }
            job.status = "error"
            job.error = shown
            job.errorDetail = String(detail.prefix(500))
        }
    }

    private func update(_ id: String, _ body: (inout MediaJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    private func filepath(_ id: String) -> String? {
        jobs.first { $0.id == id }?.filepath ?? history.first { $0.id == id }?.filepath
    }

    private func runtimeArgs() -> [String] {
        var args: [String] = []
        if let node = locateTool("node") { args.append("node:\(node)") }
        if let deno = locateTool("deno") { args.append("deno:\(deno)") }
        return args
    }

    private func workID(_ work: Work) -> String {
        switch work {
        case .probe(let id), .download(let id): return id
        }
    }

    private func pollClipboard() {
        guard settings.clipboardWatch else { return }
        let board = NSPasteboard.general
        let change = board.changeCount
        if change == lastClipboardChange { return }
        lastClipboardChange = change
        guard let text = board.string(forType: .string), clipboardIsOnlyURLs(text) else { return }
        let now = Date()
        let activeURLs = Set(jobs.filter { $0.isActive || $0.status == "review" }.map(\.url))
        for url in extractURLs(text) {
            if activeURLs.contains(url) { continue }
            if let last = recent[url], now.timeIntervalSince(last) < 20 { continue }
            enqueue(url: url, title: url, playlistItems: nil, source: "clipboard", known: false)
        }
    }

    private func persistHistory() {
        let payload: [[String: Any]] = history.map { job in
            var item: [String: Any] = [
                "id": job.id,
                "url": job.url,
                "title": job.title,
                "status": "done",
                "created_at": job.createdAt,
                "source": job.source,
            ]
            if let thumbnail = job.thumbnail { item["thumbnail"] = thumbnail }
            if let extractor = job.extractor { item["extractor"] = extractor }
            if let duration = job.duration { item["duration"] = duration }
            if let filepath = job.filepath { item["filepath"] = filepath }
            if let playlistItems = job.playlistItems { item["playlist_items"] = playlistItems }
            return item
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: historyURL)
        }
    }

    private static func loadSettings(from url: URL, fallback: String) -> Settings {
        var settings = Settings(downloadDir: fallback)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return settings
        }
        if let dir = object["download_dir"] as? String, !dir.isEmpty {
            settings.downloadDir = (dir as NSString).expandingTildeInPath
        }
        if let preset = object["preset"] as? String, presets.contains(where: { $0.id == preset }) {
            settings.preset = preset
        }
        if let subtitles = object["subtitles"] as? Bool { settings.subtitles = subtitles }
        if let watch = object["clipboard_watch"] as? Bool { settings.clipboardWatch = watch }
        if let concurrent = object["concurrent"] as? NSNumber {
            settings.concurrent = min(3, max(1, concurrent.intValue))
        }
        let browsers = ["safari", "chrome", "whale", "firefox", "edge", "brave"]
        if let cookies = object["cookies_browser"] as? String, browsers.contains(cookies) {
            settings.cookiesBrowser = cookies
        }
        return settings
    }

    private static func loadHistory(from url: URL) -> [MediaJob] {
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array.compactMap { item in
            guard let dict = item as? [String: Any],
                  let id = dict["id"] as? String,
                  let url = dict["url"] as? String else { return nil }
            return MediaJob(
                id: id,
                url: url,
                title: (dict["title"] as? String) ?? url,
                status: "done",
                thumbnail: dict["thumbnail"] as? String,
                extractor: dict["extractor"] as? String,
                duration: dict["duration"] as? String,
                filepath: dict["filepath"] as? String,
                playlistItems: dict["playlist_items"] as? String,
                source: (dict["source"] as? String) ?? "paste",
                createdAt: (dict["created_at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            )
        }
    }
}
