// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import Toolbox

/// Rung-3 (`mrcCompress`) per-page driver. The driver never touches Ghostscript, so these tests
/// call it directly with a no-op runner. It is reached directly rather than through `compress`
/// because the routing/D7 gate (Task 15) is not yet wired — until then `compress` ignores the MRC
/// parameters and these tests are the only entry point.
final class CompressEngineMRCTests: XCTestCase {

    /// The driver needs no gs; this runner exists only to satisfy the `CompressEngine`
    /// initialiser and must never be invoked.
    private struct UnusedRunner: GhostscriptRunning {
        func run(arguments: [String], readPaths: [URL], writePaths: [URL],
                 onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
            XCTFail("mrcCompress must never call Ghostscript")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
    }

    private func makeEngine() -> CompressEngine { CompressEngine(runner: UnusedRunner()) }

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrc-driver-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.canonical
    }

    /// Mixed fixture, real classifier: the text page is MRC-encoded, the photo page falls outside
    /// the eligibility envelope and ships its JPEG fallback — both recorded, document composes.
    func testMixedDocumentEncodesTextPageAndFallsBackPhotoPage() async throws {
        let engine = makeEngine()
        let input = try Fixtures.mixedColourScanPDF()
        let work = try makeWorkDir()

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        let unwrapped = try XCTUnwrap(result, "a mixed document with one MRC page must compose")
        XCTAssertEqual(unwrapped.report.verdicts.count, 2, "every page must be recorded")
        guard case .mrcEncoded = unwrapped.report.verdicts[0] else {
            return XCTFail("the text page must be MRC-encoded, got \(unwrapped.report.verdicts[0])")
        }
        guard case .fallback = unwrapped.report.verdicts[1] else {
            return XCTFail("the photo page must fall back, got \(unwrapped.report.verdicts[1])")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrapped.url.path))
        XCTAssertGreaterThan(unwrapped.bytes, 0)
        XCTAssertNotNil(PDFDocument(url: unwrapped.url), "the composed hybrid must be a valid PDF")
    }

    /// Verify-before-compose (D6), THE smear regression (spec §9). Both pages are forced past the
    /// classifier; the verifier is overridden to fail the **second** page (the photo pushed through
    /// MRC via `forceEligible`). That page must ship its JPEG fallback while the first still ships
    /// MRC — the swap happens before composition, so no smeared page ever reaches the output.
    func testVerifierRejectionSwapsPageBeforeComposition() async throws {
        let engine = makeEngine()
        let input = try Fixtures.mixedColourScanPDF()
        let work = try makeWorkDir()

        // A reference counter, not a captured `var`, so the non-escaping override is safe to call
        // from the async driver. The verifier is scored once per attempted page, in page order.
        final class Counter { var n = 0 }
        let counter = Counter()
        let failSecond: (MRCVerifier.Score) -> MRCVerifier.Score = { score in
            counter.n += 1
            return counter.n == 2 ? MRCVerifier.Score(normalisedError: 5, pass: false) : score
        }

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work,
                                                   forceEligible: true,
                                                   verifierOverride: failSecond) { _ in }

        let unwrapped = try XCTUnwrap(result, "the document must still compose around the swapped page")
        XCTAssertEqual(unwrapped.report.verdicts.count, 2)
        guard case .mrcEncoded = unwrapped.report.verdicts[0] else {
            return XCTFail("the passing page must be MRC-encoded, got \(unwrapped.report.verdicts[0])")
        }
        guard case .fallback(.verifierRejected) = unwrapped.report.verdicts[1] else {
            return XCTFail("the rejected page must fall back as verifierRejected, got "
                           + "\(unwrapped.report.verdicts[1])")
        }
        XCTAssertNotNil(PDFDocument(url: unwrapped.url))
    }

    /// A document over `maxMRCPages` declines whole-document (nil) before any per-page work — no
    /// partial output is written.
    func testPageCapDeclines() async throws {
        let engine = makeEngine()
        let input = try Fixtures.blankPDF(pages: CompressEngine.maxMRCPages + 1)
        let work = try makeWorkDir()

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        XCTAssertNil(result, "a document past the page cap must decline")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("mrc.pdf").path),
            "an over-cap decline must not write partial work")
    }

    /// One complex page (born-digital vector text appended to an otherwise-eligible scan) fails the
    /// structural sweep, so the whole document declines (R2) rather than rasterising the text page.
    func testComplexPageDisqualifiesDocument() async throws {
        let engine = makeEngine()
        let scan = try Fixtures.colourTextScanPDF(pages: 1)
        let born = try Fixtures.bornDigitalPDF(pages: 1)

        let document = try XCTUnwrap(PDFDocument(url: scan))
        let bornPage = try XCTUnwrap(PDFDocument(url: born)?.page(at: 0))
        document.insert(try XCTUnwrap(bornPage.copy() as? PDFPage), at: document.pageCount)
        let input = scan.deletingLastPathComponent().appendingPathComponent("scan-plus-text.pdf")
        XCTAssertTrue(document.write(to: input))
        XCTAssertEqual(PDFDocument(url: input)?.pageCount, 2, "fixture precondition")

        let work = try makeWorkDir()
        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        XCTAssertNil(result, "a document carrying a complex page must decline whole-document")
    }

    /// Cancellation mid-page-loop rethrows `CancellationError`, never a silent decline. The
    /// structural sweep checks cancellation at the top of its loop before any per-page work, so
    /// cancelling immediately after dispatch is deterministic.
    func testCancellationRethrows() async throws {
        let engine = makeEngine()
        let input = try Fixtures.colourTextScanPDF(pages: 2)
        let work = try makeWorkDir()

        let handle = Task {
            try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }
        }
        handle.cancel()

        do {
            let result = try await handle.value
            XCTFail("expected the cancelled driver to rethrow, got \(String(describing: result))")
        } catch is CancellationError {
            // expected
        }
    }
}
