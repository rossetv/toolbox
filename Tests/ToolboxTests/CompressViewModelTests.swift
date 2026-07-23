// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import XCTest
@testable import Toolbox

/// Drives `CompressViewModel` exactly as the view does — the full batch/preset/estimate/
/// output-folder GUI path (Track C, Task C.2), end to end, with no UI harness involved (the
/// view itself has no logic beyond calling into this model).
@MainActor
final class CompressViewModelTests: XCTestCase {

    /// `compress()` reserves an output name for every job it snapshots, but several MainActor hops
    /// separate that snapshot from the queue launching anything. A file added in that window would
    /// be `.queued`, so the live batch would run it — with no reserved name, allocating from
    /// inside a concurrent job body and racing the very collision the reservation prevents. Both
    /// the "+ Add" button and the drop handler call `add` unconditionally, so the window is
    /// reachable by an ordinary user dropping a file just as a batch starts.
    func testAddIsIgnoredWhileABatchIsRunning() async throws {
        let model = CompressViewModel()
        XCTAssertNil(model.loadError)

        let inputs = [try Fixtures.imagePDF(), try Fixtures.textImagePDF()]
        model.outputFolder = inputs[0].deletingLastPathComponent()
        model.add(inputs)
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }

        model.compress()
        XCTAssertTrue(model.isRunning)

        // The drop that lands a moment too late.
        model.add([try Fixtures.bornDigitalPDF()])
        XCTAssertEqual(model.jobs.count, 2,
                       "a file added mid-batch must not join the running batch unreserved")

        try await waitUntil(timeout: 60) { !model.isRunning }
        // And once the batch is over, adding works normally again.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 3 }
    }

    func testThreeFileSyntheticBatchCompressesEndToEnd() async throws {
        let model = CompressViewModel()
        XCTAssertNil(model.loadError, "Ghostscript should resolve from the test host bundle")

        // Three distinct basenames: a shared output folder collision-avoidance race between
        // same-named concurrent jobs is a separate, pre-existing FileNaming concern (reported
        // separately) — this test proves the batch/estimate/preset/output-folder path C.2 owns.
        // (bilevelPDF() is deliberately avoided here too — compressing it through the real
        // engine at .balanced fails OutputValidator's blank-page check, a second separate
        // pre-existing issue in the shared CompressEngine/OutputValidator/Fixtures path,
        // reproduced standalone and reported rather than fixed here.)
        let inputs = [try Fixtures.imagePDF(), try Fixtures.textImagePDF(), try Fixtures.bornDigitalPDF()]
        let outputFolder = inputs[0].deletingLastPathComponent()
        model.outputFolder = outputFolder

        model.add(inputs)
        try await waitUntil(timeout: 5) { model.jobs.count == 3 }

        // Every queued job should pick up a (possibly fallback) estimate promptly — the
        // estimator is time-boxed to 500 ms, so this should settle well inside 5 s for 3 files.
        try await waitUntil(timeout: 5) {
            model.jobs.allSatisfy { $0.estimate != nil }
        }
        for job in model.jobs {
            XCTAssertNotNil(job.estimate)
            XCTAssertGreaterThan(job.estimate!.predictedBytes, 0)
        }

        XCTAssertTrue(model.canCompress)
        model.compress()
        XCTAssertTrue(model.isRunning)

        try await waitUntil(timeout: 30) {
            model.jobs.allSatisfy { if case .queued = $0.state { return false }
                                     if case .analysing = $0.state { return false }
                                     if case .running = $0.state { return false }
                                     return true }
        }
        try await waitUntil(timeout: 5) { !model.isRunning }

        // Every job reached a terminal, real (queue-driven) outcome — not a leftover estimate.
        for job in model.jobs {
            switch job.state {
            case .done(.compressed(let before, let after)):
                XCTAssertGreaterThan(before, 0)
                XCTAssertGreaterThan(after, 0)
                XCTAssertLessThan(after, before)
            case .done(.noGain):
                break   // the tiny born-digital fixture may legitimately not shrink
            case .failed(let message):
                XCTFail("job for \(job.url.lastPathComponent) failed: \(message)")
            default:
                XCTFail("expected a terminal state, got \(job.state)")
            }
        }

        // Output landed in the chosen folder, one file per input, named "-compressed".
        for input in inputs {
            let expected = outputFolder.appendingPathComponent(
                "\(input.deletingPathExtension().lastPathComponent)-compressed.pdf")
            let job = try XCTUnwrap(model.jobs.first { $0.url == input })
            if case .done(.compressed) = job.state {
                XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                              "expected compressed output at \(expected.path)")
            }
        }
    }

    func testChangingPresetReestimatesQueuedJobs() async throws {
        let model = CompressViewModel()
        let input = try Fixtures.imagePDF()
        model.add([input])

        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }
        let balancedEstimate = try XCTUnwrap(model.jobs.first?.estimate)

        model.preset = .smallestSize
        // The preset change invalidates the old estimate; wait for a fresh one under the
        // new preset (the model briefly clears to .analysing then repopulates `estimate`).
        try await waitUntil(timeout: 5) {
            guard let job = model.jobs.first else { return false }
            guard let estimate = job.estimate else { return false }
            return estimate.predictedBytes != balancedEstimate.predictedBytes || estimate.isFallback
        }
    }

    // MARK: helpers

    private struct TimedOut: Error, CustomStringConvertible {
        let seconds: TimeInterval
        var description: String { "condition not met within \(seconds)s" }
    }

    /// Polls `condition` until true or `timeout` elapses — a genuine timeout is a **test
    /// failure** (thrown, not skipped): this guards real async completion, not an
    /// environment precondition.
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw TimedOut(seconds: timeout)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
