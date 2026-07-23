// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
import PDFKit
@testable import Toolbox

final class MRCClassifierTests: XCTestCase {
    /// A scan fixture page is exactly one image, no text, no vector paint.
    func testSingleImageScanPageIsSimple() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.greyscaleScanPDF()))
        XCTAssertEqual(MRCClassifier.structure(of: try XCTUnwrap(doc.page(at: 0))), .simpleSingleImage)
    }

    /// A born-digital page has text operators → complex (R2: rasterising it would destroy
    /// selectable text, so the whole document must take the plain gs path).
    func testBornDigitalPageIsComplex() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.bornDigitalPDF()))
        XCTAssertEqual(MRCClassifier.structure(of: try XCTUnwrap(doc.page(at: 0))), .complex)
    }

    /// Structure is about shape, not content — the photo fixture is still one image, no text,
    /// no vector paint, so it must still classify as simple even though its signal profile
    /// (Task 6) will later fail the MRC envelope.
    func testPhotoScanPageIsSimpleSingleImage() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.colourPhotoScanPDF()))
        XCTAssertEqual(MRCClassifier.structure(of: try XCTUnwrap(doc.page(at: 0))), .simpleSingleImage)
    }

    /// An annotation on an otherwise-simple scan page must fail closed to `.complex` — MRC
    /// would clobber the annotation on rasterisation.
    func testAnnotatedPageIsComplex() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.greyscaleScanPDF()))
        let page = try XCTUnwrap(doc.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20),
                                        forType: .text, withProperties: nil)
        page.addAnnotation(annotation)
        XCTAssertEqual(MRCClassifier.structure(of: page), .complex)
    }
}
