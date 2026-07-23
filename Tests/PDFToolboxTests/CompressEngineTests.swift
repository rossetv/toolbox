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

    func testSparseBilevelValidatesNotFalselyRejected() async throws {
        // Regression (found in Track C integration): a legitimately sparse scan — a few lines of
        // text with wide margins — once tripped the OutputValidator blank-page check after real gs
        // downsampling and was wrongly rejected as validationFailed, silently dropping the job. It
        // must now complete: either compressed or no-gain, never a validation failure.
        let engine = try makeEngine()
        let input = try Fixtures.bilevelPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("bilevel-compressed.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        switch outcome {
        case .compressed, .noGain: break   // both acceptable; the point is it did NOT throw validationFailed
        default: XCTFail("expected .compressed or .noGain, got \(outcome)")
        }
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

    // MARK: M1 — a cancelled compression delivers nothing

    /// Cancel while gs is running. The stub's output is a **deliverable** one — valid, smaller,
    /// same page count, and (the input being blank) it passes `OutputValidator` — so without the
    /// engine's cancellation checks this run would place a file in the user's folder, which is
    /// exactly the reported defect. The assertions are therefore both discriminating.
    func testCancelDuringGhostscriptRunDeliversNoOutput() async throws {
        let input = try Fixtures.blankPDF(pages: 1)
        let output = input.deletingLastPathComponent().appendingPathComponent("cancelled-compressed.pdf")

        let smaller = Self.minimalBlankPDF()
        XCTAssertNotNil(PDFDocument(data: smaller), "the stub output must be a valid PDF")
        XCTAssertLessThan(smaller.count, TestSupport.fileSize(input),
                          "the stub output must be a genuine gain, or the engine would return .noGain")

        let entered = XCTestExpectation(description: "gs run entered")
        let gate = Gate()
        let engine = CompressEngine(runner: GatedRunner(bytes: smaller, entered: entered, release: gate))

        let handle = Task {
            try await engine.compress(input, preset: .balanced, to: output) { _ in }
        }
        await fulfillment(of: [entered], timeout: 5)
        handle.cancel()
        await gate.open()

        do {
            let outcome = try await handle.value
            XCTFail("expected the cancelled compression to throw, got \(outcome)")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a cancelled job must leave no output file")
    }

    /// A hand-built one-page PDF (~350 bytes) — smaller than anything CoreGraphics or PDFKit
    /// emits, so a stub "compression" of a blank fixture is a genuine size gain. Offsets are
    /// computed, never hand-counted, so the xref is correct by construction.
    private static func minimalBlankPDF() -> Data {
        let bodies = ["<< /Type /Catalog /Pages 2 0 R >>",
                      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in bodies.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\n"
            + "startxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}

/// Deterministic handshake: lets the test cancel exactly while the "gs run" is in flight, with no
/// ordering race (open-before-wait returns immediately).
private actor Gate {
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

/// A stub runner that parks mid-run until the test releases it, then writes a valid, smaller
/// output — i.e. a run that *would* be delivered if cancellation were ignored.
private struct GatedRunner: GhostscriptRunning {
    let bytes: Data
    let entered: XCTestExpectation
    let release: Gate

    func run(arguments: [String],
             readPaths: [URL],
             writePaths: [URL],
             onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
        entered.fulfill()
        await release.wait()
        if let path = arguments.first(where: { $0.hasPrefix("-sOutputFile=") })
            .map({ String($0.dropFirst("-sOutputFile=".count)) }) {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
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
