// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import XCTest
@testable import PDFToolbox

/// Deterministic handshake for tests: lets a job body suspend until the test opens the gate,
/// with no ordering race (open-before-wait returns immediately).
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ToolQueueTests: XCTestCase {

    private func urls(_ n: Int, _ tag: String) -> [URL] {
        (0..<n).map { URL(fileURLWithPath: "/tmp/pdftoolbox-\(tag)-\($0).pdf") }
    }

    func testAllJobsReachDone() async {
        let queue = ToolQueue()
        queue.add(urls(5, "done"))
        await queue.run({ _, _ in .compressed(before: 10, after: 5) }, maxConcurrent: 2)

        XCTAssertEqual(queue.jobs.count, 5)
        for job in queue.jobs {
            XCTAssertEqual(job.state, .done(.compressed(before: 10, after: 5)))
        }
    }

    func testProgressReportTransitionsThenDone() async {
        let queue = ToolQueue()
        queue.add(urls(1, "progress"))
        let gate = Gate()

        var observed: [JobState] = []
        let recorder = queue.$jobs.sink { jobs in
            if let state = jobs.first?.state { observed.append(state) }
        }
        let sawRunningHalf = XCTestExpectation(description: "running(0.5)")
        sawRunningHalf.assertForOverFulfill = false
        let watcher = queue.$jobs.sink { jobs in
            if jobs.first?.state == .running(0.5) { sawRunningHalf.fulfill() }
        }

        let handle = Task {
            await queue.run({ _, report in
                report(0.5)
                await gate.wait()             // suspend until the test has seen .running(0.5)
                return .compressed(before: 10, after: 5)
            }, maxConcurrent: 1)
        }

        await fulfillment(of: [sawRunningHalf], timeout: 5)
        await gate.open()
        await handle.value

        XCTAssertTrue(observed.contains(.running(0.5)), "progress transition not observed")
        XCTAssertEqual(queue.jobs.first?.state, .done(.compressed(before: 10, after: 5)))
        recorder.cancel()
        watcher.cancel()
    }

    func testThrowFailsOnlyThatJobBatchContinues() async {
        let queue = ToolQueue()
        let jobURLs = urls(5, "throw")
        queue.add(jobURLs)
        let failURL = jobURLs[2]

        await queue.run({ job, _ in
            if job.url == failURL {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
            }
            return .compressed(before: 10, after: 5)
        }, maxConcurrent: 2)

        let failed = queue.jobs.filter { if case .failed = $0.state { return true } else { return false } }
        let done = queue.jobs.filter { $0.state == .done(.compressed(before: 10, after: 5)) }
        XCTAssertEqual(failed.count, 1, "exactly one job should fail")
        XCTAssertEqual(done.count, 4, "the other four should complete")
        XCTAssertEqual(queue.jobs.first(where: { $0.url == failURL })?.state, .failed("boom"))
    }

    func testCancelLeavesRemainingQueued() async {
        let queue = ToolQueue()
        queue.add(urls(3, "cancel"))

        let started = XCTestExpectation(description: "a job started running")
        started.assertForOverFulfill = false
        let watcher = queue.$jobs.sink { jobs in
            if jobs.contains(where: { if case .running = $0.state { return true } else { return false } }) {
                started.fulfill()
            }
        }

        let handle = Task {
            await queue.run({ _, _ in
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            }, maxConcurrent: 1)
        }

        await fulfillment(of: [started], timeout: 5)
        queue.cancel()
        await handle.value

        // maxConcurrent 1: one job was running (→ back to .queued on cancel), the other two
        // never started. None reached a terminal state; no partial output (the stub writes none).
        for job in queue.jobs {
            XCTAssertEqual(job.state, .queued)
        }
        watcher.cancel()
    }

    /// M8 — a second `run` while a batch is live must not replace `runTask`, or `cancel()` would
    /// reach only the newer task and the first batch would become permanently uncancellable.
    func testSecondRunIsRefusedSoTheLiveBatchStaysCancellable() async {
        let queue = ToolQueue()
        queue.add(urls(2, "reentry"))

        let started = XCTestExpectation(description: "a job started running")
        started.assertForOverFulfill = false
        let watcher = queue.$jobs.sink { jobs in
            if jobs.contains(where: { if case .running = $0.state { return true } else { return false } }) {
                started.fulfill()
            }
        }

        let first = Task {
            await queue.run({ _, _ in
                // Bounded, so a regression fails on an assertion instead of hanging: if the cancel
                // never arrives this returns a terminal outcome and the `.queued` checks below fail.
                let deadline = Date().addingTimeInterval(5)
                while !Task.isCancelled, Date() < deadline { await Task.yield() }
                if Task.isCancelled { throw CancellationError() }
                return .compressed(before: 10, after: 5)
            }, maxConcurrent: 1)
        }
        await fulfillment(of: [started], timeout: 5)

        // Re-entry while the first batch is live: a no-op that returns at once.
        await queue.run({ _, _ in .compressed(before: 10, after: 5) }, maxConcurrent: 1)
        XCTAssertFalse(queue.jobs.contains { if case .done = $0.state { return true } else { return false } },
                       "a refused run must not process the queue behind the live batch's back")

        queue.cancel()
        await first.value

        for job in queue.jobs {
            XCTAssertEqual(job.state, .queued, "cancel() must still reach the first batch")
        }
        watcher.cancel()
    }
}
