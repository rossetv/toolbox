// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import PDFToolbox

final class CompressEngineTests: XCTestCase {

    private func makeEngine() throws -> CompressEngine {
        CompressEngine(runner: try GhostscriptRunner())   // bundled gs via Bundle.main
    }

    func testCompressImageShrinksAndValidates() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.imagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("image-compressed.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        guard case let .compressed(before, after) = outcome else {
            return XCTFail("expected .compressed, got \(outcome)")
        }
        XCTAssertLessThan(after, before, "expected a smaller output: \(before) → \(after)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        // Page count preserved and output valid.
        let inDoc = try XCTUnwrap(PDFDocument(url: input))
        let outDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outDoc.pageCount, inDoc.pageCount)
    }

    func testNoGainKeepsOriginalAndWritesNoFile() async throws {
        let engine = try makeEngine()
        // A blank page: gs's pdfwrite structure makes it *larger* than the CoreGraphics original.
        let input = try Fixtures.blankPDF(pages: 1)
        let output = input.deletingLastPathComponent().appendingPathComponent("blank-compressed.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        guard case let .noGain(bytes) = outcome else {
            return XCTFail("expected .noGain, got \(outcome)")
        }
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "no output file should be written on no-gain")
    }

    func testEncryptedInputThrows() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.encryptedPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("enc-compressed.pdf")

        do {
            _ = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a throw for an encrypted input")
        } catch CompressError.encrypted {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCorruptInputThrows() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.corruptPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("corrupt-compressed.pdf")

        do {
            _ = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a throw for a corrupt input")
        } catch CompressError.corrupt {
            // expected
        }
    }
}
