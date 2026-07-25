// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

final class BatchProgressTextTests: XCTestCase {

    func testCountsTheFileCurrentlyBeingProcessed() {
        XCTAssertEqual(batchProgressText("Compressing", finished: 0, total: 3), "Compressing 1 of 3…")
        XCTAssertEqual(batchProgressText("Compressing", finished: 2, total: 3), "Compressing 3 of 3…")
    }

    /// The regression: the last file reaches `.done` a MainActor hop before the tool clears its
    /// running flag, so `finished` can equal `total` while the bar is still on screen. Unclamped
    /// that read "Compressing 4 of 3…".
    func testClampsWhenEveryFileHasFinished() {
        XCTAssertEqual(batchProgressText("Compressing", finished: 3, total: 3), "Compressing 3 of 3…")
        XCTAssertEqual(batchProgressText("Reading", finished: 5, total: 4), "Reading 4 of 4…")
    }

    func testUsesTheVerbItIsGiven() {
        XCTAssertEqual(batchProgressText("Reading", finished: 1, total: 4), "Reading 2 of 4…")
    }
}
