// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import Toolbox

/// Task 16: cross-cutting end-to-end tests over the shipped MRC hybrid — rotation, byte-level
/// invariants, OCR interplay, and the headline "beats gs" case (spec §9). Where a hybrid wins the
/// D7 gate, `compress`'s delivered file is a byte-identical copy of `mrcCompress`'s composed
/// output (see `CompressEngine.compress`'s MRC-wins branch), so I1/I2/I4 are asserted directly on
/// `mrcCompress`'s result — "the shipped hybrid" — without paying for a second, stubbed gs pass.
/// Only the final test needs the whole `compress` path with a REAL gs, because it is the one
/// contract that is actually about beating gs.
final class MRCInvariantTests: XCTestCase {

    /// The driver never touches Ghostscript; this runner exists only to satisfy the initialiser.
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
            .appendingPathComponent("mrc-invariant-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.canonical
    }

    /// I2 end-to-end: the shipped hybrid's `/Rotate` equals the input page's, for every rotation
    /// the fixture writer supports. One page per rotation keeps the real-MRC render cost down.
    func testRotatedInputShipsSameRotation() async throws {
        for rotation in [90, 180, 270] {
            let engine = makeEngine()
            let input = try Fixtures.colourTextScanPDF(pages: 1, rotation: rotation)
            let work = try makeWorkDir()

            let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

            let unwrapped = try XCTUnwrap(result, "rotation \(rotation): the eligible page must compose")
            let inputPage = try XCTUnwrap(PDFDocument(url: input)?.page(at: 0))
            let outputPage = try XCTUnwrap(PDFDocument(url: unwrapped.url)?.page(at: 0))
            XCTAssertEqual(outputPage.rotation, inputPage.rotation,
                           "rotation \(rotation): shipped page rotation must equal the input's")
            XCTAssertEqual(outputPage.rotation, rotation)
        }
    }

    /// I1 end-to-end: every soft mask in the shipped hybrid's raw bytes carries the literal
    /// `/ColorSpace /DeviceGray`, never an `ICCBased` space (the ghost-text regression, spec §7).
    func testShippedHybridSoftMasksAreDeviceGray() async throws {
        let engine = makeEngine()
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let work = try makeWorkDir()

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        let unwrapped = try XCTUnwrap(result)
        let text = String(decoding: try Data(contentsOf: unwrapped.url), as: UTF8.self)
        XCTAssertTrue(text.contains("/ColorSpace /DeviceGray"),
                      "the shipped hybrid must carry a literal DeviceGray soft mask space")
        XCTAssertFalse(text.contains("ICCBased"),
                       "the shipped hybrid must never carry an ICC-based mask space")
    }

    /// I4: the shipped hybrid re-validates via the existing `OutputValidator` — opens, same page
    /// count, sample renders non-blank and within the retained-ink band.
    func testShippedHybridRevalidates() async throws {
        let engine = makeEngine()
        let input = try Fixtures.colourTextScanPDF(pages: 2)
        let work = try makeWorkDir()

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        let unwrapped = try XCTUnwrap(result)
        let ok = try OutputValidator().validate(input: input, output: unwrapped.url)
        XCTAssertTrue(ok, "the shipped hybrid must re-validate against its input")
    }

    /// R12 — OCR interplay: the existing OCR engine runs over a shipped hybrid exactly as it would
    /// over any other PDF the app produced. The hybrid carries no text layer on either page, so
    /// both pages are OCR'd (nothing skipped); the incremental-update output validates AND the
    /// hybrid's bytes are a verbatim prefix of the OCR output (reusing `OCREngine`'s own
    /// verbatim-prefix helper, the idiom `OCREngineTests` uses for the same net).
    func testOCRAcceptsHybridOutput() async throws {
        let compressEngine = makeEngine()
        let input = try Fixtures.mixedColourScanPDF()
        let work = try makeWorkDir()

        let result = try await compressEngine.mrcCompress(input, preset: .balanced, to: work) { _ in }
        let hybrid = try XCTUnwrap(result, "the mixed fixture's MRC-eligible page must compose")

        let ocrEngine = OCREngine()
        let ocrOutput = hybrid.url.deletingLastPathComponent().appendingPathComponent("hybrid-ocr.pdf")
        let outcome = try await ocrEngine.ocr(hybrid.url, to: ocrOutput, options: OCROptions()) { _ in }

        guard case let .ocrAdded(pages, skipped) = outcome else {
            return XCTFail("expected the image-only hybrid to be OCR'd, got \(outcome)")
        }
        XCTAssertEqual(skipped, 0, "the hybrid carries no text layer on either page")
        XCTAssertEqual(pages, try XCTUnwrap(PDFDocument(url: hybrid.url)).pageCount)

        XCTAssertTrue(try OutputValidator().validate(input: hybrid.url, output: ocrOutput),
                      "the OCR'd hybrid must re-validate against the hybrid")
        XCTAssertTrue(try OCREngine.hasVerbatimPrefix(of: hybrid.url, in: ocrOutput),
                      "the hybrid's bytes must be a verbatim prefix of the OCR output")
    }

    /// Spec §9's headline end-to-end: a mixed document (one MRC-eligible page, one that falls back
    /// to its own JPEG) beats a REAL Ghostscript pass and ships as the hybrid, with the gs output
    /// parked as the runner-up. This is the one test in the file that pays for real gs — every
    /// other case here stubs or bypasses it (cost control).
    func testEndToEndMixedDocumentBeatsGs() async throws {
        let engine = CompressEngine(runner: try GhostscriptRunner())   // bundled gs via Bundle.main
        let input = try Fixtures.mixedColourScanPDF()
        let inputBytes = try Data(contentsOf: input)
        let work = try makeWorkDir()
        let output = work.appendingPathComponent("out.pdf")
        let alternate = work.appendingPathComponent("runner-up.pdf")

        final class ReportSpy { var fired = false; var report: MRCDocumentReport? }
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.fired = true; spy.report = $0 }) { _ in }

        guard case let .compressedHeavy(before, after, runnerUpBytes) = outcome else {
            return XCTFail("expected the hybrid to beat real gs, got \(outcome)")
        }
        XCTAssertEqual(before, inputBytes.count)
        XCTAssertLessThan(after, before, "the hybrid must be smaller than the input")
        XCTAssertGreaterThan(runnerUpBytes, 0, "the real gs candidate must have shipped some bytes")

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "the hybrid must be shipped")
        XCTAssertEqual(TestSupport.fileSize(output), after)
        XCTAssertTrue(FileManager.default.fileExists(atPath: alternate.path),
                      "the real gs version must be parked as the runner-up")
        XCTAssertEqual(TestSupport.fileSize(alternate), runnerUpBytes)

        XCTAssertTrue(spy.fired, "the MRC report must fire when the hybrid ships")
        XCTAssertEqual(spy.report?.verdicts.count, 2, "both pages of the mixed fixture must be recorded")
    }
}
