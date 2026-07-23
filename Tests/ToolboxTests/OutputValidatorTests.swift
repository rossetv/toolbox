// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import XCTest
@testable import Toolbox

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

    /// Regression: `PDFService.sampleIndices` always includes just the first and last page, so a
    /// document whose only real content sits strictly between them can have every SAMPLED input
    /// page render below the content floor. The old code then returned true on "opens + same
    /// page count" alone, with zero actual content comparisons. It must widen the check until it
    /// has compared at least one real page, and must catch corruption there.
    func testCorruptionOnAnUnsampledPageIsCaught() throws {
        let input = try Self.multiPagePDF(contentOnPage: 2, pages: 5)
        let output = try Self.multiPagePDF(contentOnPage: nil, pages: 5)   // page 2's content lost
        XCTAssertFalse(try validator.validate(input: input, output: output, samplePages: 2),
                      "content lost on an unsampled page must still be caught")
    }

    /// A `pages`-page PDF that is blank everywhere except `contentOnPage` (a solid black block),
    /// or blank everywhere if `contentOnPage` is nil.
    private static func multiPagePDF(contentOnPage index: Int?, pages: Int) throws -> URL {
        let url = try Fixtures.uniqueURL("multi-\(index.map(String.init) ?? "blank")-\(UUID().uuidString).pdf")
        var media = Fixtures.letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw Fixtures.FixtureError.contextCreation
        }
        for page in 0..<pages {
            ctx.beginPDFPage(nil)
            if page == index {
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 100, y: 100, width: 400, height: 500))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url.canonical
    }
}
