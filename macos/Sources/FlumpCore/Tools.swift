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
    public let mirrors: [String]
    public let sha256: String
    public let zipEntry: String?
    public let entrySHA256: String?

    public var urls: [String] { [url] + mirrors }
}

private struct PinnedToolBody: Decodable {
    let version: String
    let url: String
    let mirrors: [String]?
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
            mirrors: body.mirrors ?? [],
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

public func toolVersionLine(_ output: String) -> String? {
    let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let token = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    guard token.contains(where: \.isNumber) else { return nil }
    return token
}

public func toolVersionIsNewer(_ candidate: String, than installed: String) -> Bool {
    let left = versionParts(candidate)
    let right = versionParts(installed)
    let count = max(left.count, right.count)
    for index in 0..<count {
        let a = index < left.count ? left[index] : 0
        let b = index < right.count ? right[index] : 0
        if a != b { return a > b }
    }
    return false
}

/// Copies a bundled tool into Application Support. An existing copy is replaced
/// only when `sourceVersion` is newer than `destinationVersion`.
@discardableResult
public func seedExecutable(
    from source: String,
    to destination: URL,
    sourceVersion: String? = nil,
    destinationVersion: String? = nil
) throws -> Bool {
    if FileManager.default.isExecutableFile(atPath: destination.path) {
        guard let sourceVersion, let destinationVersion,
              toolVersionIsNewer(sourceVersion, than: destinationVersion),
              FileManager.default.isExecutableFile(atPath: source) else {
            return false
        }
        try FileManager.default.removeItem(at: destination)
    }
    guard FileManager.default.isExecutableFile(atPath: source) else { return false }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: source, toPath: destination.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    return true
}

public func toolVersion(at path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    process.environment = ["PATH": extendedPath()]
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
    return toolVersionLine(String(data: data, encoding: .utf8) ?? "")
}

private func versionParts(_ text: String) -> [Int] {
    let token = toolVersionLine(text) ?? text
    return token.split(separator: ".").map { Int($0) ?? 0 }
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
