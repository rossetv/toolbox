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

    // MARK: FIX 2 — a gs exit-0 with no / invalid output is a FAILURE, never `.noGain`

    /// gs "succeeds" (exit 0) but writes nothing → the batch must see a failure, not a
    /// masked "already optimised". Reproduced with a stub runner because a real gs cannot be
    /// forced to exit 0 while producing an empty output.
    func testEmptyGhostscriptOutputIsFailureNotNoGain() async throws {
        let engine = CompressEngine(runner: StubRunner(exitCode: 0, output: .none))
        let input = try Fixtures.imagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("empty-compressed.pdf")

        do {
            let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a failure for empty gs output, got \(outcome)")
        } catch is CompressError {
            // expected — any CompressError, never a `.noGain`/`.compressed` return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "no output file should be written when gs produced nothing")
    }

    /// gs exits 0 and writes a blob that is ≥ the input but is not a valid PDF → this must be
    /// a failure, not `.noGain`: an invalid ≥-input output must never masquerade as no-gain.
    func testInvalidLargerOutputIsFailureNotNoGain() async throws {
        // A ≥-input, non-PDF blob (100 KB of zero bytes → `PDFDocument` returns nil).
        let blob = Data(count: 100_000)
        let engine = CompressEngine(runner: StubRunner(exitCode: 0, output: .bytes(blob)))
        let input = try Fixtures.blankPDF(pages: 1)   // a few KB → the blob is larger
        let output = input.deletingLastPathComponent().appendingPathComponent("invalid-compressed.pdf")

        do {
            let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a failure for an invalid ≥-input output, got \(outcome)")
        } catch is CompressError {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "no output file should be written for an invalid output")
    }
}

/// A test double for the gs runner. Simulates outcomes the real binary can't be forced to
/// produce: an exit-0 run that writes no output, or one that writes a chosen blob to gs's
/// `-sOutputFile=` path. Never launches a process.
private struct StubRunner: GhostscriptRunning {
    enum Output {
        case none
        case bytes(Data)
    }

    let exitCode: Int32
    let output: Output

    func run(arguments: [String],
             readPaths: [URL],
             writePaths: [URL],
             onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
        if case let .bytes(data) = output, let path = Self.outputPath(from: arguments) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return ProcessResult(exitCode: exitCode, stdout: "", stderr: "")
    }

    private static func outputPath(from arguments: [String]) -> String? {
        let flag = "-sOutputFile="
        return arguments.first { $0.hasPrefix(flag) }.map { String($0.dropFirst(flag.count)) }
    }
}
