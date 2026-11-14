import XCTest
@testable import FlumpCore

final class ToolTests: XCTestCase {
    func testPinnedToolsMatchThePublishedChecksums() {
        let tools = Dictionary(uniqueKeysWithValues: pinnedTools().map { ($0.id, $0) })
        XCTAssertEqual(tools["yt-dlp"]?.version, "2026.10.26")
        XCTAssertEqual(tools["yt-dlp"]?.sha256.count, 64)
        XCTAssertNil(tools["yt-dlp"]?.zipEntry)
        XCTAssertEqual(
            tools["ffmpeg"]?.entrySHA256,
            "6deb2860c3dc0c08e0f96bab119196c024103046fa3cc7ef72e3a77797d8553c"
        )
        XCTAssertEqual(tools["deno"]?.zipEntry, "deno")
        XCTAssertEqual(tools["deno"]?.sha256.count, 64)
    }

    func testUpdateIsDueUntilARecentCheck() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ytDlpUpdateIsDue(checkedAt: nil, now: now))
        XCTAssertFalse(ytDlpUpdateIsDue(checkedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(ytDlpUpdateIsDue(checkedAt: now.addingTimeInterval(-13 * 60 * 60), now: now))
    }

    func testSeedCopiesOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("first".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let dest = root.appendingPathComponent("bin/yt-dlp")
        XCTAssertTrue(try seedExecutable(from: source.path, to: dest))
        try Data("second".utf8).write(to: source)
        XCTAssertFalse(try seedExecutable(from: source.path, to: dest))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "first")
    }

    func testInstallRejectsABadChecksum() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(
            try installDownloadedTool(
                data: Data("hello".utf8),
                sha256: String(repeating: "ab", count: 32),
                zipEntry: nil,
                entrySHA256: nil,
                destination: dest
            )
        ) { error in
            XCTAssertEqual(error as? ToolError, .checksum)
        }
    }

    func testInstallUnpacksAZipAndChecksTheInnerFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("#!/bin/sh\necho ok\n".utf8)
        let file = root.appendingPathComponent("deno")
        try payload.write(to: file)
        let zip = root.appendingPathComponent("deno.zip")
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", zip.lastPathComponent, "deno"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = try Data(contentsOf: zip)
        let dest = root.appendingPathComponent("out/deno")
        try installDownloadedTool(
            data: data,
            sha256: sha256Hex(data),
            zipEntry: "deno",
            entrySHA256: sha256Hex(payload),
            destination: dest
        )
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))

        XCTAssertThrowsError(
            try installDownloadedTool(
                data: data,
                sha256: sha256Hex(data),
                zipEntry: "deno",
                entrySHA256: String(repeating: "cd", count: 32),
                destination: root.appendingPathComponent("out/bad")
            )
        ) { error in
            XCTAssertEqual(error as? ToolError, .checksum)
        }
    }

    func testManagedBinaryBeatsALaterPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        try Data("managed".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertEqual(locateTool("yt-dlp", binDirectory: root, path: "/usr/bin"), binary.path)
    }
}
