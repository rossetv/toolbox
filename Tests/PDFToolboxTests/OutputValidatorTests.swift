// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import PDFToolbox

final class OutputValidatorTests: XCTestCase {
    private let validator = OutputValidator()

    func testEqualCountNonBlankPasses() throws {
        let input = try Fixtures.bornDigitalPDF(pages: 2)
        let output = try Fixtures.bornDigitalPDF(pages: 2)
        XCTAssertTrue(try validator.validate(input: input, output: output, samplePages: 2))
    }

    func testPageCountMismatchFails() throws {
        let input = try Fixtures.bornDigitalPDF(pages: 3)
        let output = try Fixtures.bornDigitalPDF(pages: 2)
        XCTAssertFalse(try validator.validate(input: input, output: output, samplePages: 3))
    }

    func testBlankOutputFails() throws {
        let input = try Fixtures.bornDigitalPDF(pages: 1)
        let output = try Fixtures.blankPDF(pages: 1)
        XCTAssertFalse(try validator.validate(input: input, output: output, samplePages: 1))
    }

    /// Regression: a legitimately sparse page (few lines, wide margins) renders below any fixed
    /// "blank" threshold but is valid content — it must NOT be rejected. The old absolute-floor
    /// heuristic falsely failed this, silently dropping real compress jobs.
    func testSparseContentValidates() throws {
        let input = try Fixtures.bilevelPDF()
        let output = try Fixtures.bilevelPDF()
        XCTAssertTrue(try validator.validate(input: input, output: output, samplePages: 1))
    }

    /// A genuinely blank input paired with a blank output is not corruption (no content was lost).
    func testBlankInputBlankOutputPasses() throws {
        let input = try Fixtures.blankPDF(pages: 1)
        let output = try Fixtures.blankPDF(pages: 1)
        XCTAssertTrue(try validator.validate(input: input, output: output, samplePages: 1))
    }
}
