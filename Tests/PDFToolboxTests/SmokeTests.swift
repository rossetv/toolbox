// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import PDFToolbox

/// Proves the hosted test target is wired (TEST_HOST launches, `@testable import`
/// resolves the app module) before the real engine tests build on top of it.
final class SmokeTests: XCTestCase {
    func testToolCatalogue() {
        XCTAssertEqual(Tool.allCases.count, 4)
        XCTAssertTrue(Tool.compress.isAvailable)
        XCTAssertTrue(Tool.ocr.isAvailable)
        XCTAssertFalse(Tool.merge.isAvailable)
        XCTAssertFalse(Tool.split.isAvailable)
    }
}
