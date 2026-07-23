// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import PDFToolbox

final class PDFServiceTests: XCTestCase {
    private let service = PDFService()

    func testPageCount() throws {
        let url = try Fixtures.bornDigitalPDF(pages: 3)
        XCTAssertEqual(try service.pageCount(url), 3)
    }

    func testClassifyBornDigital() throws {
        let url = try Fixtures.bornDigitalPDF(pages: 3)
        XCTAssertEqual(try service.classify(url), .bornDigital)
    }

    func testClassifyImageScanIsColour() throws {
        let url = try Fixtures.imagePDF()
        XCTAssertEqual(try service.classify(url), .scanColour)
    }

    func testClassifyBilevelScan() throws {
        let url = try Fixtures.bilevelPDF()
        XCTAssertEqual(try service.classify(url), .scanBilevel)
    }

    func testPageHasTextTrueForBornDigital() throws {
        let url = try Fixtures.bornDigitalPDF(pages: 1)
        XCTAssertTrue(try service.pageHasText(url, index: 0))
    }

    func testPageHasTextFalseForImagePage() throws {
        let url = try Fixtures.imagePDF()
        XCTAssertFalse(try service.pageHasText(url, index: 0))
    }

    func testPageHasTextFalseForTextImage() throws {
        // Rendered words but no text layer → OCR target, not "already searchable".
        let url = try Fixtures.textImagePDF()
        XCTAssertFalse(try service.pageHasText(url, index: 0))
    }

    /// The page-taking form is what the OCR loop calls (it already holds the page); the URL form
    /// is implemented in terms of it, so the two can never drift apart.
    func testPageHasTextAgreesBetweenPageAndURLForms() throws {
        for url in [try Fixtures.bornDigitalPDF(pages: 3), try Fixtures.imagePDF()] {
            let doc = try XCTUnwrap(PDFDocument(url: url))
            for i in 0..<doc.pageCount {
                let page = try XCTUnwrap(doc.page(at: i))
                XCTAssertEqual(service.pageHasText(page), try service.pageHasText(url, index: i))
            }
        }
    }

    func testOpenGuardEncrypted() throws {
        let url = try Fixtures.encryptedPDF()
        XCTAssertEqual(try OpenGuard.inspect(url), .encrypted)
    }

    func testOpenGuardCorrupt() throws {
        let url = try Fixtures.corruptPDF()
        XCTAssertEqual(try OpenGuard.inspect(url), .corrupt)
    }

    func testOpenGuardOK() throws {
        let url = try Fixtures.bornDigitalPDF(pages: 2)
        XCTAssertEqual(try OpenGuard.inspect(url), .ok(pageCount: 2))
    }
}
