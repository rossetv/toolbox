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

    /// Regression: the ceiling half of the validation (`maxRetainedInk`). An output carrying far
    /// MORE ink than its input is corruption — an inversion, or a bilevel/MRC polarity
    /// regression — even though nothing was lost, and a floor-only check waves it through.
    /// Measured on these fixtures: the input bar reads 0.015, the flooded output 1.00, so the
    /// comparison is 66× the 3.0 ceiling.
    func testInkFloodedOutputFails() throws {
        let input = try Self.pagesPDF([[Self.bar]], label: "sparse")
        let output = try Self.pagesPDF([[Fixtures.letter]], label: "flooded")
        XCTAssertFalse(try validator.validate(input: input, output: output, samplePages: 1),
                       "an output with far more ink than its input is corruption, not compression")
    }

    /// Regression: the ceiling used to be skipped along with the floor. A page whose INPUT reads
    /// below `contentFloor` (here a folio-sized mark, 0.0003) took the `continue` meant for
    /// "nothing here to lose" and was never compared in EITHER direction — so the same page
    /// arriving inverted to solid black passed, and one dense page elsewhere in the sample was
    /// enough to return true without ever widening. The floor exists to spare blank-page noise a
    /// meaningless ratio; it was never meant to excuse a flood.
    func testInvertedPageBelowTheContentFloorIsStillCaught() throws {
        let input = try Self.pagesPDF([[Self.block], [Self.folio]], label: "near-blank-page")
        let output = try Self.pagesPDF([[Self.block], [Fixtures.letter]], label: "page-inverted")
        XCTAssertFalse(try validator.validate(input: input, output: output, samplePages: 2),
                       "a near-blank page returned as solid black must fail validation")
    }

    /// A near-blank input page whose output is legitimately near-blank too must still pass — the
    /// flood ceiling must not become the absolute floor `testSparseContentValidates` forbids.
    func testNearBlankPageStaysValid() throws {
        let input = try Self.pagesPDF([[Self.block], [Self.folio]], label: "near-blank-in")
        let output = try Self.pagesPDF([[Self.block], [Self.folio]], label: "near-blank-out")
        XCTAssertTrue(try validator.validate(input: input, output: output, samplePages: 2))
    }

    private static let block = CGRect(x: 100, y: 100, width: 400, height: 500)   // ink 0.41
    private static let bar = CGRect(x: 100, y: 400, width: 400, height: 20)      // ink 0.015
    private static let folio = CGRect(x: 300, y: 40, width: 12, height: 10)      // ink 0.0003

    /// A `pages`-page PDF that is blank everywhere except `contentOnPage` (a solid black block),
    /// or blank everywhere if `contentOnPage` is nil.
    private static func multiPagePDF(contentOnPage index: Int?, pages: Int) throws -> URL {
        let content = (0..<pages).map { $0 == index ? [Self.block] : [] }
        return try pagesPDF(content, label: "multi-\(index.map(String.init) ?? "blank")")
    }

    /// One page per element, each carrying that element's rectangles filled black (an empty
    /// element is a blank page).
    private static func pagesPDF(_ pages: [[CGRect]], label: String) throws -> URL {
        let url = try Fixtures.uniqueURL("\(label)-\(UUID().uuidString).pdf")
        var media = Fixtures.letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw Fixtures.FixtureError.contextCreation
        }
        for rects in pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            for rect in rects { ctx.fill(rect) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url.canonical
    }
}
