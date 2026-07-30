// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import XCTest
@testable import Toolbox

@MainActor
final class ToolQueueTests: XCTestCase {

    private func urls(_ n: Int, _ tag: String) -> [URL] {
        (0..<n).map { URL(fileURLWithPath: "/tmp/toolbox-\(tag)-\($0).pdf") }
    }

    func testAllJobsReachDone() async {
        let queue = ToolQueue()
        queue.add(urls(5, "done"))
        await queue.run({ _, _ in JobResult(.compressed(before: 10, after: 5)) }, maxConcurrent: 2)

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
                return JobResult(.compressed(before: 10, after: 5))
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
            return JobResult(.compressed(before: 10, after: 5))
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
                return JobResult(.compressed(before: 10, after: 5))
            }, maxConcurrent: 1)
        }
        await fulfillment(of: [started], timeout: 5)

        // Re-entry while the first batch is live: a no-op that returns at once.
        await queue.run({ _, _ in JobResult(.compressed(before: 10, after: 5)) }, maxConcurrent: 1)
        XCTAssertFalse(queue.jobs.contains { if case .done = $0.state { return true } else { return false } },
                       "a refused run must not process the queue behind the live batch's back")

        queue.cancel()
        await first.value

        for job in queue.jobs {
            XCTAssertEqual(job.state, .queued, "cancel() must still reach the first batch")
        }
        watcher.cancel()
    }

    /// MAJOR 2 — a progress tick is a separate, untracked `Task` and can land after the job
    /// already reached `.done` (exactly what `OCREngine.ocr`'s `progress(1.0)` immediately before
    /// return can do). It must not resurrect the job back to `.running`, or the job is stranded
    /// forever: `removeCompleted()` only matches `.done`/`.failed`, so it could never be cleared.
    func testLateProgressReportCannotOverwriteDoneState() async {
        let queue = ToolQueue()
        queue.add(urls(1, "late-progress"))

        final class ReportBox: @unchecked Sendable {
            var report: ((Double) -> Void)?
        }
        let box = ReportBox()

        await queue.run({ _, report in
            // Capture the report closure instead of calling it now — we call it below, AFTER the
            // job has already reached `.done`, to simulate the late-tick race deterministically.
            box.report = report
            return JobResult(.compressed(before: 10, after: 5))
        }, maxConcurrent: 1)

        XCTAssertEqual(queue.jobs.first?.state, .done(.compressed(before: 10, after: 5)))

        box.report?(0.75)
        // The report closure hops via `Task { @MainActor in ... }`; give it a moment to actually run.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(queue.jobs.first?.state, .done(.compressed(before: 10, after: 5)),
                       "a late progress report must not overwrite a terminal state")
    }

    /// MINOR 10 — the sliding window is the entire reason `ToolQueue` exists over a plain
    /// `TaskGroup` that adds every job at once; nothing previously asserted the cap is honoured,
    /// so a regression to "launch everything at once" would pass the whole rest of the suite.
    func testConcurrencyCapIsHonoured() async {
        let queue = ToolQueue()
        let total = 6
        queue.add(urls(total, "cap"))

        actor Counter {
            private var current = 0
            private var maxObserved = 0
            func increment() { current += 1; maxObserved = max(maxObserved, current) }
            func decrement() { current -= 1 }
            func peak() -> Int { maxObserved }
        }
        let counter = Counter()
        let cap = 2

        await queue.run({ _, _ in
            await counter.increment()
            // Hold the slot open long enough that any jobs launched beyond the cap would overlap
            // with these — if the window isn't honoured, this is what makes the overrun visible.
            try? await Task.sleep(nanoseconds: 100_000_000)
            await counter.decrement()
            return JobResult(.compressed(before: 10, after: 5))
        }, maxConcurrent: cap)

        let peak = await counter.peak()
        XCTAssertEqual(peak, cap, "at most \(cap) of \(total) jobs should ever run concurrently, saw \(peak)")
    }

    /// MINOR 10 — Reveal-in-Finder depends on `resultURL` being set AND attributed to the correct
    /// job; nothing previously asserted either. Distinct per-job URLs make misattribution visible.
    func testResultURLIsAttributedToTheCorrectJob() async {
        let queue = ToolQueue()
        let inputs = urls(4, "result-url")
        queue.add(inputs)

        let expected = Dictionary(uniqueKeysWithValues: inputs.map { input in
            (input, URL(fileURLWithPath: "/tmp/toolbox-result-\(input.lastPathComponent)"))
        })

        await queue.run({ job, _ in
            JobResult(.compressed(before: 10, after: 5), outputURL: expected[job.url])
        }, maxConcurrent: 3)

        for job in queue.jobs {
            XCTAssertEqual(job.resultURL, expected[job.url],
                           "resultURL must be attributed to the job it belongs to")
        }
    }

    /// m1 — `add` while a batch is live must be a no-op, matching `run`'s own re-entrancy guard:
    /// a job appended after `execute`'s `queuedIDs` snapshot is taken would never be picked up by
    /// this batch and would sit `.queued` forever with no UI signal.
    func testAddWhileRunningIsRefused() async {
        let queue = ToolQueue()
        queue.add(urls(1, "add-while-running"))

        let started = XCTestExpectation(description: "a job started running")
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
        queue.add(urls(1, "should-be-refused"))
        XCTAssertEqual(queue.jobs.count, 1, "an add while the batch is live must not enqueue anything")

        queue.cancel()
        await handle.value
        watcher.cancel()
    }

    /// T9 — the empty-batch path through `execute` (`queuedIDs.isEmpty`, `launchNext()` no-ops
    /// `maxConcurrent` times, `withTaskGroup` with zero children) was never exercised.
    func testRunOnEmptyQueueCompletesImmediately() async {
        let queue = ToolQueue()
        await queue.run({ _, _ in JobResult(.compressed(before: 10, after: 5)) }, maxConcurrent: 2)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    /// T9 — a duplicate URL queued twice must be tracked as two independent jobs (distinct `id`s),
    /// each reaching its own terminal state.
    func testDuplicateURLsAreTrackedAsIndependentJobs() async {
        let queue = ToolQueue()
        let url = URL(fileURLWithPath: "/tmp/toolbox-dup.pdf")
        queue.add([url, url])

        XCTAssertEqual(queue.jobs.count, 2)
        XCTAssertNotEqual(queue.jobs[0].id, queue.jobs[1].id)

        await queue.run({ _, _ in JobResult(.compressed(before: 10, after: 5)) }, maxConcurrent: 2)

        XCTAssertEqual(queue.jobs.count, 2)
        for job in queue.jobs {
            XCTAssertEqual(job.url, url)
            XCTAssertEqual(job.state, .done(.compressed(before: 10, after: 5)))
        }
    }

    /// A body returning an alternateURL must land it on the job, next to resultURL —
    /// the Rung-3 runner-up channel.
    func testAlternateURLFromJobResultLandsOnJob() async throws {
        let queue = ToolQueue()
        queue.add([URL(fileURLWithPath: "/tmp/a.pdf")])
        let alt = URL(fileURLWithPath: "/tmp/alt.pdf")
        await queue.run { _, _ in
            JobResult(.compressedHeavy(before: 100, after: 40, runnerUpBytes: 60),
                      outputURL: URL(fileURLWithPath: "/tmp/out.pdf"), alternateURL: alt)
        }
        XCTAssertEqual(queue.jobs.first?.alternateURL, alt)
        XCTAssertEqual(queue.jobs.first?.state,
                       .done(.compressedHeavy(before: 100, after: 40, runnerUpBytes: 60)))
    }
}
