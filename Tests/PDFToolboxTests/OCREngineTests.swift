// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import PDFToolbox

final class OCREngineTests: XCTestCase {

    /// An image-only page with rendered words becomes searchable, and the outcome reports one
    /// OCR'd page and nothing skipped.
    func testImagePageBecomesSearchable() async throws {
        let engine = OCREngine()
        let input = try Fixtures.textImagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("text-image-ocr.pdf")

        let outcome = try await engine.ocr(input, to: output, options: OCROptions()) { _ in }

        guard case let .ocrAdded(pages, skipped) = outcome else {
            return XCTFail("expected .ocrAdded, got \(outcome)")
        }
        XCTAssertEqual(pages, 1)
        XCTAssertEqual(skipped, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let text = (try XCTUnwrap(PDFDocument(url: output)).page(at: 0)?.string ?? "").uppercased()
        XCTAssertTrue(text.contains("HELLO") || text.contains("WORLD"),
                      "expected the rendered words to be recognised, got: \(text.debugDescription)")
    }

    /// A fully born-digital document already has text everywhere → nothing to OCR.
    func testBornDigitalIsAlreadySearchable() async throws {
        let engine = OCREngine()
        let input = try Fixtures.bornDigitalPDF(pages: 2)
        let output = input.deletingLastPathComponent().appendingPathComponent("born-ocr.pdf")

        let outcome = try await engine.ocr(input, to: output, options: OCROptions()) { _ in }

        XCTAssertEqual(outcome, .alreadySearchable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "an already-searchable doc writes no output")
    }

    /// A mixed document skips the page that already has text and OCRs the image page.
    func testMixedSkipsTextPageAndOCRsImagePage() async throws {
        let engine = OCREngine()

        // Assemble a 2-page mixed input in-test (born-digital page + image page) via PDFKit —
        // shared Fixtures stay untouched.
        let bornURL = try Fixtures.bornDigitalPDF(pages: 1)
        let imageURL = try Fixtures.textImagePDF()
        let mixed = PDFDocument()
        mixed.insert(try XCTUnwrap(PDFDocument(url: bornURL)?.page(at: 0)), at: 0)
        mixed.insert(try XCTUnwrap(PDFDocument(url: imageURL)?.page(at: 0)), at: 1)
        let mixedURL = bornURL.deletingLastPathComponent().appendingPathComponent("mixed.pdf")
        XCTAssertTrue(mixed.write(to: mixedURL))

        let output = mixedURL.deletingLastPathComponent().appendingPathComponent("mixed-ocr.pdf")
        let outcome = try await engine.ocr(mixedURL, to: output, options: OCROptions()) { _ in }

        guard case let .ocrAdded(pages, skipped) = outcome else {
            return XCTFail("expected .ocrAdded, got \(outcome)")
        }
        XCTAssertEqual(skipped, 1, "the born-digital page should be skipped")
        XCTAssertEqual(pages, 1, "the image page should be OCR'd")

        let outDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outDoc.pageCount, 2, "page count preserved")
    }

    /// Encrypted and corrupt inputs fail inline (the batch would continue with the rest).
    func testEncryptedInputThrows() async throws {
        let engine = OCREngine()
        let input = try Fixtures.encryptedPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("enc-ocr.pdf")
        do {
            _ = try await engine.ocr(input, to: output, options: OCROptions()) { _ in }
            XCTFail("expected a throw for an encrypted input")
        } catch OCRError.encrypted {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCorruptInputThrows() async throws {
        let engine = OCREngine()
        let input = try Fixtures.corruptPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("corrupt-ocr.pdf")
        do {
            _ = try await engine.ocr(input, to: output, options: OCROptions()) { _ in }
            XCTFail("expected a throw for a corrupt input")
        } catch OCRError.corrupt {
            // expected
        }
    }
}
