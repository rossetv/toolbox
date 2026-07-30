// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import Toolbox

final class OCREngineTests: XCTestCase {

    /// An image-only page with rendered words becomes searchable, and the outcome reports one
    /// OCR'd page and nothing skipped.
    func testImagePageBecomesSearchable() async throws {
        let engine = OCREngine()
        let input = try Fixtures.textImagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("text-image-ocr.pdf")

        let outcome = try await engine.ocr(input, to: output, options: OCROptions()) { _ in }

        guard case let .added(pages, skipped) = outcome.ocr else {
            return XCTFail("expected an added-text leg, got \(outcome)")
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

        XCTAssertEqual(outcome.ocr, .alreadySearchable)
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

        guard case let .added(pages, skipped) = outcome.ocr else {
            return XCTFail("expected an added-text leg, got \(outcome)")
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

    /// M3 — a page no raster can be made of cannot be recognised, so the file is declined. The old
    /// behaviour counted it in `pages` and delivered the document as searchable.
    func testPageThatCannotBeRasterisedFailsTheFile() async throws {
        let engine = OCREngine()
        let input = try Fixtures.degeneratePageScanPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("degenerate-ocr.pdf")

        do {
            let outcome = try await engine.ocr(input, to: output, options: OCROptions()) { _ in }
            XCTFail("expected the unrenderable page to fail the file, got \(outcome)")
        } catch let error as OCRError {
            guard case .unrenderablePage(let index) = error else {
                return XCTFail("expected .unrenderablePage, got \(error)")
            }
            XCTAssertEqual(index, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a declined file leaves nothing behind")
    }

    /// m9 — a blank scan is recognised, yields nothing, and must not be handed back as a
    /// byte-identical copy reported as searchable: no file, and the too-faint verdict — recognition
    /// completed with zero usable runs on the pages that lacked a layer (spec §6.3).
    func testScanWithNothingToRecogniseWritesNoFile() async throws {
        let engine = OCREngine()
        let input = try Fixtures.blankPDF(pages: 1)
        let output = input.deletingLastPathComponent().appendingPathComponent("blank-ocr.pdf")

        let outcome = try await engine.ocr(input, to: output, options: OCROptions()) { _ in }

        XCTAssertEqual(outcome.ocr, .tooFaint,
                       "no page gained text, and the outcome must say so")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a duplicate of the input is not an OCR result")
    }

    // MARK: - Recognised-text bound (M4)

    /// §4.4 — the recognised text accumulates for the whole document, so it carries a named bound,
    /// and a document past it is declined rather than delivered with a truncated text layer.
    func testRecognisedTextBoundDeclinesTheFile() throws {
        XCTAssertEqual(try OCREngine.accumulate(runs: 10, adding: 5), 15)
        XCTAssertEqual(try OCREngine.accumulate(runs: OCREngine.maxRecognisedTextRuns - 1, adding: 1),
                       OCREngine.maxRecognisedTextRuns,
                       "the bound itself is still accepted")
        XCTAssertThrowsError(try OCREngine.accumulate(runs: OCREngine.maxRecognisedTextRuns,
                                                      adding: 1)) { error in
            guard case OCRError.recognisedTextTooLarge = error else {
                return XCTFail("expected .recognisedTextTooLarge, got \(error)")
            }
        }
    }

    // MARK: - Raster bound (S8)

    /// An ordinary page is unaffected: Letter at 300 DPI is still exactly 2550 × 3300.
    func testOrdinaryPageRastersAtFullResolution() {
        let size = OCREngine.rasterSize(displayed: CGSize(width: 612, height: 792), dpi: 300)
        XCTAssertEqual(size, CGSize(width: 2550, height: 3300))
    }

    /// `/MediaBox` is attacker-controlled. At the specification's own maximum page — 14400 pt —
    /// an unclamped 300-DPI render is 60,000 px a side, about 14 GB for one page.
    func testHugeMediaBoxIsClampedRatherThanAllocated() throws {
        let size = try XCTUnwrap(OCREngine.rasterSize(displayed: CGSize(width: 14400, height: 14400),
                                                      dpi: 300))
        XCTAssertLessThanOrEqual(size.width * size.height, OCREngine.maxRasterPixels)
        XCTAssertEqual(size.width, size.height, accuracy: 1, "the aspect ratio must be preserved")
        XCTAssertGreaterThan(size.width, 1000, "clamped, not collapsed")
    }

    /// A wildly out-of-range box is clamped on total pixels, not on either edge alone.
    func testExtremeAspectRatioIsClampedOnTotalPixels() throws {
        let size = try XCTUnwrap(OCREngine.rasterSize(displayed: CGSize(width: 200_000, height: 400),
                                                      dpi: 300))
        XCTAssertLessThanOrEqual(size.width * size.height, OCREngine.maxRasterPixels)
    }

    func testDegeneratePageSizesAreRefused() {
        XCTAssertNil(OCREngine.rasterSize(displayed: CGSize(width: 0, height: 792), dpi: 300))
        XCTAssertNil(OCREngine.rasterSize(displayed: CGSize(width: -1, height: 792), dpi: 300))
        XCTAssertNil(OCREngine.rasterSize(displayed: CGSize(width: CGFloat.nan, height: 792), dpi: 300))
        XCTAssertNil(OCREngine.rasterSize(displayed: CGSize(width: CGFloat.infinity, height: 792), dpi: 300))
        XCTAssertNil(OCREngine.rasterSize(displayed: CGSize(width: 0.01, height: 0.01), dpi: 1))
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

    /// T5 — the helper above is only worth having if the engine *enforces* it. This drives the
    /// whole fail-loud net with an output that opens cleanly and has the right page count, so the
    /// verbatim-prefix guard is the only one that can fire: delete it and this test goes green
    /// against a rewritten file, which is exactly the writer desync §3.5 exists to catch.
    func testValidationRejectsAnOutputThatIsNotAVerbatimAppend() throws {
        let engine = OCREngine()
        let input = try Fixtures.textImagePDF()
        let output = input.deletingLastPathComponent()
            .appendingPathComponent("resaved-\(UUID().uuidString).pdf")
        let doc = try XCTUnwrap(PDFDocument(url: input))
        XCTAssertTrue(doc.write(to: output))

        XCTAssertNotNil(PDFDocument(url: output), "precondition: the doctored output still opens")
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, doc.pageCount,
                       "precondition: the page-count guard must not be what fires")
        XCTAssertFalse(try OCREngine.hasVerbatimPrefix(of: input, in: output),
                       "precondition: a re-serialised copy is not a verbatim append")

        do {
            try engine.validateOCROutput(input: input, output: output,
                                         textPages: [], pageCount: doc.pageCount)
            XCTFail("an output that is not the input's verbatim prefix must be rejected")
        } catch OCRError.validationFailed {
            // expected
        }
    }
}

// MARK: - recognise / append split (the `OCRing` seam)

extension OCREngineTests {

    /// The split is a re-expression, not a new behaviour: `recognise` then `append` reports the
    /// same outcome and delivers the same searchable file as the one-shot `ocr(_:to:options:_:)`.
    func testRecogniseThenAppendEqualsOcr() async throws {
        let engine = OCREngine()
        let input = try Fixtures.textImagePDF()
        let dir = input.deletingLastPathComponent()

        let viaOneShot = dir.appendingPathComponent("one-shot-\(UUID().uuidString).pdf")
        let outcome = try await engine.ocr(input, to: viaOneShot, options: OCROptions()) { _ in }

        let recognised = try await engine.recognise(input, options: OCROptions()) { _ in }
        let viaSplit = dir.appendingPathComponent("split-\(UUID().uuidString).pdf")
        try engine.append(recognised, to: input, output: viaSplit)

        XCTAssertEqual(recognised.pageCount, 1)
        XCTAssertEqual(recognised.pagesRecognised, 1)
        XCTAssertEqual(recognised.pagesSkipped, 0)
        XCTAssertEqual(recognised.outcome, .added(pages: 1, skipped: 0),
                       "the named partition is what the queue's OCR leg reads")
        XCTAssertEqual(recognised.outcome, outcome.ocr,
                       "the partition must agree with the one-shot path's own outcome")

        for output in [viaOneShot, viaSplit] {
            let name = output.lastPathComponent
            XCTAssertTrue(try OCREngine.hasVerbatimPrefix(of: input, in: output),
                          "\(name): every append keeps the input as its verbatim prefix")
            let doc = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(doc.pageCount, 1, "\(name): page count preserved")
            let text = (doc.page(at: 0)?.string ?? "").uppercased()
            XCTAssertTrue(text.contains("HELLO") || text.contains("WORLD"),
                          "\(name): expected the recognised words, got \(text.debugDescription)")
        }
    }

    /// The geometry rule (spec §6.4): recognition records the ORIGINAL page's geometry, but the
    /// append projects Vision's normalised boxes onto the **target's own** geometry. A `/Rotate 90`
    /// scan composed by the MRC path becomes a `/Rotate 0` page whose MediaBox is the original's
    /// *displayed* size — so the layer must land the right way up, over the words a reader sees,
    /// not in the corner the original's portrait MediaBox would put it in.
    func testAppendToComposedGeometry() async throws {
        let engine = OCREngine()
        let input = try Self.rotatedWordScanPDF(rotation: 90)

        let recognised = try await engine.recognise(input, options: OCROptions()) { _ in }
        let runs = try XCTUnwrap(recognised.pageText[0], "the rotated scan must recognise its words")
        XCTAssertFalse(runs.isEmpty)
        XCTAssertEqual(recognised.geometry[0],
                       PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 90),
                       "recognition records the ORIGINAL geometry — the append must not reuse it")

        let work = try Self.workDir()
        let hybrid = try await CompressEngine(runner: UnusedGhostscriptRunner())
            .mrcCompress(input, preset: .balanced, to: work) { _ in }
        let composed = try XCTUnwrap(
            hybrid, "the fixture page must compose — the composed target is what this test is about").url

        let composedPage = try XCTUnwrap(PDFDocument(url: composed)?.page(at: 0))
        XCTAssertEqual(composedPage.rotation, 0,
                       "precondition: the composed page bakes /Rotate into its pixels")
        let media = composedPage.bounds(for: .mediaBox)
        XCTAssertEqual(media.width, 792, accuracy: 1,
                       "precondition: the composed MediaBox is the original's DISPLAYED size")
        XCTAssertEqual(media.height, 612, accuracy: 1)

        let output = work.appendingPathComponent("composed-ocr.pdf")
        try engine.append(recognised, to: composed, output: output)

        let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)

        // Where Vision saw the words, normalised in the original's DISPLAYED space …
        let seen = runs.dropFirst().reduce(runs[0].boundingBox) { $0.union($1.boundingBox) }
        XCTAssertLessThan(seen.width * seen.height, 0.6,
                          "precondition: the fixture confines its ink to one band, so a "
                          + "mis-projected layer cannot accidentally land on top of it")

        // … and where the appended layer actually is, normalised the same way. Reading start and
        // vertical band are exact; the run's LENGTH is not, and must not be asserted as though it
        // were: `PDFWriter.placement` fits each run to its box from a 0.5-em average-advance
        // estimate, so a line of wide uppercase glyphs typesets past the box's right edge. That
        // slack is horizontal only — a layer projected from the wrong geometry misses by half a
        // page on every axis, which is what these tolerances still catch.
        let landed = try XCTUnwrap(Self.normalisedTextBounds(of: page),
                                   "the appended layer must carry positioned characters")
        XCTAssertEqual(landed.minX, seen.minX, accuracy: 0.06, "layer reading start (x)")
        XCTAssertEqual(landed.minY, seen.minY, accuracy: 0.06, "layer band bottom (y)")
        XCTAssertEqual(landed.maxY, seen.maxY, accuracy: 0.06, "layer band top (y)")
        XCTAssertEqual(landed.maxX, seen.maxX, accuracy: 0.15, "layer run extent (x)")

        // Selectable *at* that position: a reader dragging over the words gets them. The drag
        // covers the typeset run, which per the note above reaches beyond the recognised box.
        let longest = try XCTUnwrap(runs.max { $0.text.count < $1.text.count })
        let n = longest.boundingBox
        let hit = CGRect(x: box.minX + n.minX * box.width, y: box.minY + n.minY * box.height,
                         width: n.width * box.width * 1.6, height: n.height * box.height)
            .insetBy(dx: -6, dy: -6)
        let selected = (page.selection(for: hit)?.string ?? "").uppercased()
        XCTAssertTrue(selected.contains(longest.text.uppercased()),
                      "expected \(longest.text.debugDescription) to be selectable at the upright "
                      + "position, got \(selected.debugDescription)")
    }

    /// The append writes a new file and only reads its target — the parked variant it is handed
    /// keeps its bytes, and stays the output's verbatim prefix.
    func testAppendNeverTouchesTarget() async throws {
        let engine = OCREngine()
        let input = try Fixtures.textImagePDF()
        let dir = input.deletingLastPathComponent()
        let target = dir.appendingPathComponent("target-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: input, to: target)
        let before = try Data(contentsOf: target)

        let recognised = try await engine.recognise(input, options: OCROptions()) { _ in }
        let output = dir.appendingPathComponent("target-ocr-\(UUID().uuidString).pdf")
        try engine.append(recognised, to: target, output: output)

        XCTAssertEqual(try Data(contentsOf: target), before,
                       "append must never write to the file it appends FROM")
        XCTAssertTrue(try OCREngine.hasVerbatimPrefix(of: target, in: output),
                      "the target's bytes must be the output's verbatim prefix")
        XCTAssertGreaterThan(TestSupport.fileSize(output), before.count,
                             "the output is the target plus an appended layer")
    }

    /// The original the layer was recognised FROM is never modified — not by recognition, not by
    /// an append to some other variant, not by the one-shot path.
    func testOriginalNeverModified() async throws {
        let engine = OCREngine()
        let input = try Fixtures.textImagePDF()
        let dir = input.deletingLastPathComponent()
        let before = try Data(contentsOf: input)

        let recognised = try await engine.recognise(input, options: OCROptions()) { _ in }
        XCTAssertEqual(try Data(contentsOf: input), before, "recognition only reads")

        let target = dir.appendingPathComponent("variant-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: input, to: target)
        try engine.append(recognised, to: target,
                          output: dir.appendingPathComponent("variant-ocr-\(UUID().uuidString).pdf"))
        XCTAssertEqual(try Data(contentsOf: input), before, "appending to a variant leaves the original alone")

        _ = try await engine.ocr(input, to: dir.appendingPathComponent("one-shot-\(UUID().uuidString).pdf"),
                                 options: OCROptions()) { _ in }
        XCTAssertEqual(try Data(contentsOf: input), before, "the one-shot path leaves the original alone")
    }

    /// A target with a different page count is not the document that was recognised: the boxes
    /// would land on the wrong pages, so the append is refused before anything is written.
    func testAppendPageCountMismatchThrows() async throws {
        let engine = OCREngine()
        let input = try Fixtures.textImagePDF()                       // 1 page
        let recognised = try await engine.recognise(input, options: OCROptions()) { _ in }

        let target = try Fixtures.bornDigitalPDF(pages: 2)            // 2 pages
        let output = target.deletingLastPathComponent()
            .appendingPathComponent("mismatch-ocr-\(UUID().uuidString).pdf")

        XCTAssertThrowsError(try engine.append(recognised, to: target, output: output)) { error in
            guard case OCRError.validationFailed = error else {
                return XCTFail("expected .validationFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a refused append leaves nothing behind")
    }

    /// The named partition's too-faint leg, driven by the REAL engine: a blank scan is recognised
    /// (so pages ran) and yields nothing, which is `.tooFaint` — never `.added(pages: 0)`.
    func testZeroRunRecognitionMapsToTooFaint() async throws {
        let engine = OCREngine()
        let recognised = try await engine.recognise(try Fixtures.blankPDF(pages: 1),
                                                    options: OCROptions()) { _ in }

        XCTAssertEqual(recognised.pagesRecognised, 1, "the page was rendered and recognised")
        XCTAssertEqual(recognised.pagesSkipped, 0)
        XCTAssertTrue(recognised.pageText.isEmpty, "recognition found no usable runs")
        XCTAssertEqual(recognised.outcome, .tooFaint)
    }

    // MARK: fixture

    private static func workDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.canonical
    }

    /// A Letter scan of REAL words carrying `/Rotate`, MRC-eligible.
    ///
    /// Wholly synthetic. The palette is `Fixtures.colourTextScanPDF`'s proven one (cream paper,
    /// blue-black ink) so the classifier's chroma gates behave the same, but the ink is actual
    /// Helvetica text — Vision has to be able to read it — drawn **rotated a quarter turn
    /// anticlockwise** so that the viewer's clockwise `/Rotate 90` presents it horizontally, the
    /// way a rotated scan of a portrait page actually reaches the user. The lines sit in one band
    /// (low `x` unrotated ⇒ the top of the displayed page), leaving the rest of the sheet blank:
    /// that asymmetry is what makes a mis-projected text layer visible to the assertions.
    private static func rotatedWordScanPDF(rotation: Int) throws -> URL {
        let w = 1700, h = 2200
        let bmp = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bmp.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let font = CTFontCreateWithName("Helvetica" as CFString, 46, nil)
        let ink = CGColor(red: 0.05, green: 0.08, blue: 0.35, alpha: 1)
        let lines = ["THE QUICK BROWN FOX JUMPS", "OVER THE LAZY DOG NEAR", "THE RIVER BANK AT DAWN",
                     "WHILE SEVEN GREY BIRDS", "WATCH FROM THE OLD FENCE",
                     "AND THE MORNING LIGHT", "SPREADS ACROSS THE FIELD", "IN QUIET EARLY HOURS"]
        for (i, line) in lines.enumerated() {
            bmp.saveGState()
            bmp.translateBy(x: CGFloat(240 + i * 110), y: 520)
            bmp.rotate(by: .pi / 2)                     // reads upright once /Rotate 90 is applied
            drawInk(line, in: bmp, font: font, colour: ink)
            bmp.restoreGState()
        }
        let image = try XCTUnwrap(bmp.makeImage())

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotated-word-scan-\(UUID().uuidString).pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
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

    private static func drawInk(_ string: String, in ctx: CGContext, font: CTFont, colour: CGColor) {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                           kCTForegroundColorAttributeName: colour]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!
        ctx.textPosition = .zero
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
    }

    /// The bounding box of every positioned, non-whitespace character on `page`, normalised
    /// against its MediaBox — where the text layer actually landed, in the same 0…1 displayed
    /// space Vision reports its boxes in (the composed page carries no `/Rotate`).
    private static func normalisedTextBounds(of page: PDFPage) -> CGRect? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let characters = Array(page.string ?? "")
        var union: CGRect?
        for i in 0..<page.numberOfCharacters where i < characters.count {
            guard !characters[i].isWhitespace else { continue }
            let bounds = page.characterBounds(at: i)
            guard bounds.width > 0, bounds.height > 0,
                  bounds.minX.isFinite, bounds.minY.isFinite,
                  bounds.maxX.isFinite, bounds.maxY.isFinite else { continue }
            union = union.map { $0.union(bounds) } ?? bounds
        }
        guard let union else { return nil }
        return CGRect(x: (union.minX - box.minX) / box.width, y: (union.minY - box.minY) / box.height,
                      width: union.width / box.width, height: union.height / box.height)
    }
}

/// `mrcCompress` never shells out; this exists only to satisfy `CompressEngine`'s initialiser.
private struct UnusedGhostscriptRunner: GhostscriptRunning {
    func run(arguments: [String], readPaths: [URL], writePaths: [URL],
             onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
        XCTFail("the MRC path must never call Ghostscript")
        return ProcessResult(exitCode: 1, stdout: "", stderr: "")
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
