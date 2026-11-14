import XCTest
@testable import FlumpCore

final class LaneSchedulerTests: XCTestCase {
    func testDownloadsOverlapUpToTheLimit() async {
        let scheduler = await MainActor.run { LaneScheduler(probeLimit: 1, downloadLimit: 2) }
        let box = OverlapBox()
        await MainActor.run {
            scheduler.runDownload = { _ in
                await box.enter()
                try? await Task.sleep(nanoseconds: 200_000_000)
                await box.leave()
            }
            scheduler.enqueueDownload("a")
            scheduler.enqueueDownload("b")
            scheduler.enqueueDownload("c")
        }
        let finished = await box.waitFinished(3)
        let maxSeen = await box.maxSeen
        XCTAssertTrue(finished)
        XCTAssertEqual(maxSeen, 2)
    }

    func testASlowProbeDoesNotBlockADownload() async {
        let scheduler = await MainActor.run { LaneScheduler(probeLimit: 1, downloadLimit: 1) }
        let log = EventLog()
        await MainActor.run {
            scheduler.runProbe = { _ in
                await log.add("probe-start")
                try? await Task.sleep(nanoseconds: 300_000_000)
                await log.add("probe-end")
            }
            scheduler.runDownload = { _ in
                await log.add("download-start")
            }
            scheduler.enqueueProbe("slow")
            scheduler.enqueueDownload("file")
        }
        let sawDownload = await log.waitUntilContains("download-start")
        let events = await log.snapshot()
        XCTAssertTrue(sawDownload)
        let downloadAt = events.firstIndex(of: "download-start")
        XCTAssertNotNil(downloadAt)
        if let downloadAt, let probeEnd = events.firstIndex(of: "probe-end") {
            XCTAssertLessThan(downloadAt, probeEnd)
        }
    }

    func testCancelDropsQueuedWork() async {
        let scheduler = await MainActor.run { LaneScheduler(probeLimit: 1, downloadLimit: 1) }
        let log = EventLog()
        await MainActor.run {
            scheduler.runDownload = { id in
                await log.add(id)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            scheduler.enqueueDownload("a")
            scheduler.enqueueDownload("b")
            scheduler.cancel("b")
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let events = await log.snapshot()
        XCTAssertEqual(events, ["a"])
    }
}

private actor OverlapBox {
    private var current = 0
    private(set) var maxSeen = 0
    private var finished = 0

    func enter() {
        current += 1
        maxSeen = max(maxSeen, current)
    }

    func leave() {
        current -= 1
        finished += 1
    }

    func waitFinished(_ count: Int) async -> Bool {
        let start = ContinuousClock.now
        while finished < count {
            if start.duration(to: .now) > .seconds(4) { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}

private actor EventLog {
    private var events: [String] = []

    func add(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }

    func waitUntilContains(_ event: String) async -> Bool {
        let start = ContinuousClock.now
        while !events.contains(event) {
            if start.duration(to: .now) > .seconds(2) { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}
