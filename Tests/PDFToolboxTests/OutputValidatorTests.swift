// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
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
}
