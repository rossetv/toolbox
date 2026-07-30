// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
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

    /// I2 end-to-end: a rotated page comes back the SAME WAY UP a viewer sees it — not turned twice.
    ///
    /// The fix bakes `/Rotate` into the shipped pixels and drops the `/Rotate` stamp, so the old
    /// assertion (shipped `/Rotate` == input `/Rotate`) *encoded the bug*: it green-lit a page that
    /// was rotated once in the pixels and again by the stamp. This compares what a **viewer** shows
    /// (`PDFPage.thumbnail`, which applies `/Rotate`) for the input vs the shipped page — never the
    /// `render()` under test — over an asymmetric fixture, and asserts (a) the shipped page carries
    /// `/Rotate 0`, (b) it is not blank (the 90/270 clip regression), (c) its displayed aspect
    /// matches the input's, and (d) its orientation matches the input's, not the 180° flip.
    func testRotatedInputShipsSameRotation() async throws {
        for rotation in [90, 180, 270] {
            let engine = makeEngine()
            let input = try Self.asymmetricColourScanPDF(rotation: rotation)
            let work = try makeWorkDir()

            let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

            let unwrapped = try XCTUnwrap(result, "rotation \(rotation): the eligible page must compose")
            let inputPage = try XCTUnwrap(PDFDocument(url: input)?.page(at: 0))
            let outputPage = try XCTUnwrap(PDFDocument(url: unwrapped.url)?.page(at: 0))

            XCTAssertEqual(outputPage.rotation, 0,
                           "rotation \(rotation): the shipped page must carry /Rotate 0 (rotation baked in)")

            let before = Self.viewerInkGrid(inputPage)
            let after = Self.viewerInkGrid(outputPage)

            XCTAssertGreaterThan(after.ink, 0.001,
                                 "rotation \(rotation): the shipped page must not render blank")
            XCTAssertEqual(Double(after.w) / Double(after.h),
                           Double(before.w) / Double(before.h), accuracy: 0.05,
                           "rotation \(rotation): the shipped displayed aspect must match the input's")

            let toInput = Self.gridDistance(after.grid, before.grid)
            let toFlipped = Self.gridDistance(after.grid, Array(before.grid.reversed()))
            XCTAssertLessThan(toInput, toFlipped,
                              "rotation \(rotation): the shipped page must match the input's "
                              + "orientation, not its 180° flip (the double-rotation regression)")
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

        guard case let .added(pages, skipped) = outcome.ocr else {
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

        guard case let .compressed(before, after) = outcome.compress,
              outcome.shippedVariant == .mrc,
              let retained = outcome.runnerUp else {
            return XCTFail("expected the hybrid to beat real gs, got \(outcome)")
        }
        let runnerUpBytes = retained.bytes
        XCTAssertEqual(retained.kind, .plain, "the PARKED variant is the real gs output")
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

    // MARK: rotation helpers

    /// A synthetic colour text-scan (sparse dark-blue text-like bars on cream) that stays inside
    /// the MRC classifier's eligibility envelope — low moderate-chroma coverage, small components —
    /// while concentrating all its ink in the **top half** of the page. That spatial asymmetry is
    /// what makes a 180° flip unambiguous (a solid block would fail the mean-component-size gate and
    /// dense bars the chroma gate, so neither is used). `rotation` writes `/Rotate` on the page.
    /// Wholly synthetic — no reference to any real document.
    private static func asymmetricColourScanPDF(rotation: Int) throws -> URL {
        let w = 1700, h = 2200
        let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bmp.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bmp.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.35, alpha: 1))
        // Bitmap origin is bottom-left, so high y is the top of the page: rows live in the top half
        // only, leaving the bottom half blank — the decisive up/down asymmetry for the flip check.
        var y = Double(h) - 200
        while y > Double(h) * 0.5 {
            var x = 120.0
            while x < Double(w) - 80 {
                let barWidth = Double.random(in: 18...44)
                bmp.fill(CGRect(x: x, y: y, width: barWidth, height: 12))
                x += barWidth + 8 + Double.random(in: 0...6)
            }
            y -= 84
        }
        let image = bmp.makeImage()!

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("asym-colour-\(UUID().uuidString).pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(url as CFURL, mediaBox: &media, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: CGRect(x: 18, y: 18, width: 576, height: 756))
        pdf.endPDFPage()
        pdf.closePDF()

        guard rotation != 0 else { return url.canonical }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        doc.page(at: 0)?.rotation = rotation
        XCTAssertTrue(doc.write(to: url))
        return url.canonical
    }

    /// A coarse `cells×cells` map of a page's ink **as a viewer sees it** — `PDFPage.thumbnail`
    /// applies `/Rotate`, so this is the viewer-true orientation, deliberately NOT the `render()`
    /// under test. Returns the grid (mean darkness per cell, 0…1), the whole-page ink mean, and the
    /// thumbnail's pixel dimensions (aspect).
    static func viewerInkGrid(_ page: PDFPage, cells: Int = 8)
        -> (grid: [Double], ink: Double, w: Int, h: Int) {
        let thumb = page.thumbnail(of: NSSize(width: 400, height: 400), for: .mediaBox)
        guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ([], 0, 0, 0)
        }
        let w = cg.width, h = cg.height
        let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        gray.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let buf = gray.data!.assumingMemoryBound(to: UInt8.self)
        var sum = [Double](repeating: 0, count: cells * cells)
        var cnt = [Double](repeating: 0, count: cells * cells)
        for py in 0..<h {
            let cy = min(cells - 1, py * cells / h)
            for px in 0..<w {
                let cx = min(cells - 1, px * cells / w)
                sum[cy * cells + cx] += buf[py * w + px] < 128 ? 1 : 0
                cnt[cy * cells + cx] += 1
            }
        }
        var grid = [Double](repeating: 0, count: cells * cells)
        for i in 0..<grid.count where cnt[i] > 0 { grid[i] = sum[i] / cnt[i] }
        let ink = grid.reduce(0, +) / Double(grid.count)
        return (grid, ink, w, h)
    }

    /// Mean absolute difference between two equal-length ink grids.
    static func gridDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var s = 0.0
        for i in 0..<a.count { s += abs(a[i] - b[i]) }
        return s / Double(a.count)
    }
}
