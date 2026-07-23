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

    /// M2 — a cancelled OCR run stops at its next page boundary and delivers nothing. The task is
    /// held at a gate until the test has cancelled it, so there is no race between cancellation
    /// and the first page: recognition never starts and no output is written.
    func testCancelledRunStopsAndWritesNoOutput() async throws {
        let engine = OCREngine()
        let input = try Fixtures.textImagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("cancelled-ocr.pdf")

        let gate = OCRGate()
        let handle = Task {
            await gate.wait()
            return try await engine.ocr(input, to: output, options: OCROptions()) { _ in }
        }
        handle.cancel()
        await gate.open()

        do {
            let outcome = try await handle.value
            XCTFail("expected the cancelled OCR run to throw, got \(outcome)")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a cancelled OCR job must leave no output file")
    }
}

// MARK: - fail-loud validation net

extension OCREngineTests {
    /// The net's core check: a genuine incremental-update output keeps the original file as its
    /// verbatim prefix, and ANY tampering inside that region is detected. This is what turns a
    /// writer desync into a loud per-file failure instead of a silently corrupt document.
    func testVerbatimPrefixDetectsTamperedOriginalRegion() throws {
        let input = try Fixtures.textImagePDF()
        let original = try Data(contentsOf: input)

        // A faithful append: original bytes, verbatim, plus appended content.
        let good = input.deletingLastPathComponent().appendingPathComponent("good-\(UUID().uuidString).pdf")
        try (original + Data("\n% appended incremental section\n".utf8)).write(to: good)
        XCTAssertTrue(try OCREngine.hasVerbatimPrefix(of: input, in: good),
                      "a verbatim append must validate")

        // A desynced write: one byte altered inside the original region.
        var tampered = original
        tampered[tampered.count / 2] = tampered[tampered.count / 2] &+ 1
        let bad = input.deletingLastPathComponent().appendingPathComponent("bad-\(UUID().uuidString).pdf")
        try (tampered + Data("\n% appended\n".utf8)).write(to: bad)
        XCTAssertFalse(try OCREngine.hasVerbatimPrefix(of: input, in: bad),
                       "a single altered byte in the original region must be caught")

        // A truncated write must not pass either.
        let short = input.deletingLastPathComponent().appendingPathComponent("short-\(UUID().uuidString).pdf")
        try original.prefix(original.count / 2).write(to: short)
        XCTAssertFalse(try OCREngine.hasVerbatimPrefix(of: input, in: short),
                       "an output shorter than the original must be caught")
    }
}

/// Holds a task until the test has cancelled it, with no ordering race (open-before-wait
/// returns immediately).
private actor OCRGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
