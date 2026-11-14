import CryptoKit
import Foundation

public enum ToolError: Error, Equatable {
    case checksum
    case archive
    case network
}

public struct PinnedTool: Equatable, Sendable {
    public let id: String
    public let version: String
    public let url: String
    public let sha256: String
    public let zipEntry: String?
    public let entrySHA256: String?
}

private struct PinnedToolBody: Decodable {
    let version: String
    let url: String
    let sha256: String
    let zipEntry: String?
    let entrySHA256: String?
}

public func flumpSupportDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Flump", isDirectory: true)
}

public func flumpBinDirectory() -> URL {
    flumpSupportDirectory().appendingPathComponent("bin", isDirectory: true)
}

public func pinnedTools() -> [PinnedTool] {
    guard let url = Bundle.module.url(forResource: "PinnedTools", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let object = try? JSONDecoder().decode([String: PinnedToolBody].self, from: data) else {
        return []
    }
    return object.map { id, body in
        PinnedTool(
            id: id,
            version: body.version,
            url: body.url,
            sha256: body.sha256,
            zipEntry: body.zipEntry,
            entrySHA256: body.entrySHA256
        )
    }.sorted { $0.id < $1.id }
}

public func pinnedTool(_ id: String) -> PinnedTool? {
    pinnedTools().first { $0.id == id }
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func ytDlpUpdateIsDue(checkedAt: Date?, now: Date, interval: TimeInterval = 12 * 60 * 60) -> Bool {
    guard let checkedAt else { return true }
    return now.timeIntervalSince(checkedAt) >= interval
}

/// Copies the bundled yt-dlp into Application Support the first time. A later
/// copy is left alone so `--update-to stable` can replace it.
@discardableResult
public func seedExecutable(from source: String, to destination: URL) throws -> Bool {
    if FileManager.default.isExecutableFile(atPath: destination.path) {
        return false
    }
    guard FileManager.default.isExecutableFile(atPath: source) else { return false }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: source, toPath: destination.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    return true
}

public func installDownloadedTool(
    data: Data,
    sha256: String,
    zipEntry: String?,
    entrySHA256: String?,
    destination: URL
) throws {
    guard sha256Hex(data) == sha256.lowercased() else { throw ToolError.checksum }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    if let zipEntry {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = temp.appendingPathComponent("tool.zip")
        try data.write(to: archive)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", archive.path, "-d", temp.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let found = findEntry(named: zipEntry, under: temp) else {
            throw ToolError.archive
        }
        let fileData = try Data(contentsOf: found)
        if let entrySHA256, sha256Hex(fileData) != entrySHA256.lowercased() {
            throw ToolError.checksum
        }
        try FileManager.default.copyItem(at: found, to: destination)
    } else {
        try data.write(to: destination)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
}

public func runTool(_ binary: String, arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.environment = ["PATH": extendedPath()]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

private func findEntry(named name: String, under root: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return nil
    }
    for case let url as URL in enumerator {
        if url.path.contains("__MACOSX") { continue }
        guard url.lastPathComponent == name else { continue }
        let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if isFile { return url }
    }
    return nil
}
