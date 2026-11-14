import Foundation

public enum OutputLine: Sendable {
    case stdout(String)
    case stderr(String)
}

public final class YtDlpSession: @unchecked Sendable {
    private let process: Process
    private let exitBox: ExitBox
    private let state: StreamState
    public let lines: AsyncStream<OutputLine>

    public init(binary: String, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        let exitBox = ExitBox()
        let state = StreamState()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            exitBox.finish(finished.terminationStatus)
        }
        let (stream, continuation) = AsyncStream<OutputLine>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            state.read(handle, side: .stdout, continuation: continuation)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            state.read(handle, side: .stderr, continuation: continuation)
        }
        self.process = process
        self.exitBox = exitBox
        self.state = state
        self.lines = stream
        try process.run()
    }

    public func cancel() {
        if process.isRunning {
            process.terminate()
        }
    }

    public func exitCode() async -> Int32 {
        await exitBox.wait()
    }

    public func snapshot() -> (file: String?, error: String?) {
        state.snapshot()
    }
}

private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var code: Int32?

    func finish(_ code: Int32) {
        lock.lock()
        let continuation = self.continuation
        if continuation == nil {
            self.code = code
        } else {
            self.continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: code)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let code {
                lock.unlock()
                continuation.resume(returning: code)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private enum PipeSide {
    case stdout
    case stderr
}

private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutPending = Data()
    private var stderrPending = Data()
    private var stdoutEnded = false
    private var stderrEnded = false
    private var file: String?
    private var error: String?

    func read(_ handle: FileHandle, side: PipeSide, continuation: AsyncStream<OutputLine>.Continuation) {
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            let leftover = flush(side)
            for line in leftover {
                note(line)
                yield(line, side: side, continuation: continuation)
            }
            var shouldFinish = false
            lock.lock()
            switch side {
            case .stdout: stdoutEnded = true
            case .stderr: stderrEnded = true
            }
            shouldFinish = stdoutEnded && stderrEnded
            lock.unlock()
            if shouldFinish {
                continuation.finish()
            }
            return
        }
        let lines = takeLines(data, side: side)
        for line in lines {
            note(line)
            yield(line, side: side, continuation: continuation)
        }
    }

    private func yield(_ line: String, side: PipeSide, continuation: AsyncStream<OutputLine>.Continuation) {
        switch side {
        case .stdout: continuation.yield(.stdout(line))
        case .stderr: continuation.yield(.stderr(line))
        }
    }

    private func flush(_ side: PipeSide) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let pending: Data
        switch side {
        case .stdout:
            pending = stdoutPending
            stdoutPending.removeAll()
        case .stderr:
            pending = stderrPending
            stderrPending.removeAll()
        }
        let text = String(data: pending, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? [] : [text]
    }

    func snapshot() -> (file: String?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (file, error)
    }

    private func takeLines(_ data: Data, side: PipeSide) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        switch side {
        case .stdout:
            stdoutPending.append(data)
            return drain(&stdoutPending)
        case .stderr:
            stderrPending.append(data)
            return drain(&stderrPending)
        }
    }

    private func drain(_ pending: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let chunk = pending.subdata(in: 0..<newline)
            pending.removeSubrange(0...newline)
            guard var text = String(data: chunk, encoding: .utf8) else { continue }
            if text.hasSuffix("\r") { text.removeLast() }
            lines.append(text)
        }
        return lines
    }

    private func note(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if line.hasPrefix("FLUMPFILE ") {
            let path = line.dropFirst("FLUMPFILE ".count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { file = path }
        }
        if line.contains("ERROR:") {
            let detail = cleanMessage(line)
            if !detail.isEmpty { error = detail }
        }
    }
}
