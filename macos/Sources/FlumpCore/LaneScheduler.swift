import Foundation

/// Probe and download each have their own limit, so a slow lookup does not
/// hold up a save that is already waiting.
@MainActor
public final class LaneScheduler {
    public var probeLimit: Int
    public var downloadLimit: Int
    public var runProbe: @MainActor (String) async -> Void
    public var runDownload: @MainActor (String) async -> Void

    private var probes: [String] = []
    private var downloads: [String] = []
    private var activeProbes = 0
    private var activeDownloads = 0
    private var cancelled = Set<String>()

    public init(probeLimit: Int, downloadLimit: Int) {
        self.probeLimit = max(1, probeLimit)
        self.downloadLimit = max(1, downloadLimit)
        self.runProbe = { _ in }
        self.runDownload = { _ in }
    }

    public func setLimits(probe: Int, download: Int) {
        probeLimit = max(1, probe)
        downloadLimit = max(1, download)
        pump()
    }

    public func enqueueProbe(_ id: String) {
        probes.append(id)
        pump()
    }

    public func enqueueDownload(_ id: String) {
        downloads.append(id)
        pump()
    }

    public func cancel(_ id: String) {
        cancelled.insert(id)
        probes.removeAll { $0 == id }
        downloads.removeAll { $0 == id }
    }

    public func pump() {
        while activeProbes < probeLimit, !probes.isEmpty {
            let id = probes.removeFirst()
            if cancelled.contains(id) { continue }
            activeProbes += 1
            let run = runProbe
            Task {
                await run(id)
                activeProbes -= 1
                pump()
            }
        }
        while activeDownloads < downloadLimit, !downloads.isEmpty {
            let id = downloads.removeFirst()
            if cancelled.contains(id) { continue }
            activeDownloads += 1
            let run = runDownload
            Task {
                await run(id)
                activeDownloads -= 1
                pump()
            }
        }
    }
}
