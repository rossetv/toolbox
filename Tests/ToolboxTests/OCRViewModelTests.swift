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
final class OCRViewModelTests: XCTestCase {

    /// M2 — the OCR tool had no cancel at all. `cancel()` must reach the view model's own queue,
    /// so an in-flight batch stops and its files return to `.queued`. The batch is driven with a
    /// stub body here (the real `OCREngine` is not injectable); the engine's own cancellation is
    /// covered by `OCREngineTests.testCancelledRunStopsAndWritesNoOutput`.
    func testCancelStopsTheViewModelsQueue() async {
        let model = OCRViewModel()
        model.queue.add((0..<3).map { URL(fileURLWithPath: "/tmp/toolbox-ocr-cancel-\($0).pdf") })

        let started = XCTestExpectation(description: "a job started running")
        started.assertForOverFulfill = false
        let watcher = model.queue.$jobs.sink { jobs in
            if jobs.contains(where: { if case .running = $0.state { return true } else { return false } }) {
                started.fulfill()
            }
        }

        let handle = Task {
            await model.queue.run({ _, _ in
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            }, maxConcurrent: 1)
        }

        await fulfillment(of: [started], timeout: 5)
        model.cancel()
        await handle.value

        for job in model.queue.jobs {
            XCTAssertEqual(job.state, .queued, "a cancelled OCR batch must leave every file queued")
        }
        watcher.cancel()
    }
}
