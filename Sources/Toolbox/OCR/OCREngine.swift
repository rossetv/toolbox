// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum OCRError: Error, LocalizedError {
    case encrypted
    case corrupt
    case sameInputOutput
    case validationFailed
    case unrenderablePage(index: Int)
    case recognisedTextTooLarge

    var errorDescription: String? {
        switch self {
        case .encrypted: return "The PDF is password-protected."
        case .corrupt: return "The PDF is damaged and cannot be read."
        case .sameInputOutput: return "The output path must differ from the input."
        case .validationFailed: return "The OCR'd PDF failed validation."
        case .unrenderablePage(let index):
            return "Page \(index + 1) could not be rendered for recognition."
        case .recognisedTextTooLarge: return "This PDF holds more text than OCR can process."
        }
    }
}

/// One document's recognition results, produced **once** from the original and appended to every
/// variant a job delivers (spec §6.4).
struct RecognisedDocument {
    /// Vision-normalised boxes (0…1, bottom-left origin, in each page's **displayed** space) for
    /// the pages that gained text. Pages that recognised nothing carry no entry.
    let pageText: [Int: [PositionedText]]
    /// The **original** page geometry, per index — the record of what was recognised, not the
    /// projection target: `OCREngine.append` derives the geometry it writes against from the
    /// target document, so the same runs land correctly on a composed variant (see `append`).
    let geometry: [Int: PageGeometry]
    let pagesRecognised: Int
    let pagesSkipped: Int
    let pageCount: Int

    /// The row's OCR outcome for this recognition — the single named partition every consumer
    /// reads, so "zero usable runs" cannot be re-derived (and re-derived differently) at each
    /// call site. `.cancelled`/`.failed` are the *caller's* outcomes, never this one's: a
    /// recognition that returns at all completed.
    var outcome: OCROutcome {
        pagesRecognised == 0 && pagesSkipped == pageCount
            ? .alreadySearchable
            : (pagesRecognised > 0 && pageText.isEmpty
                ? .tooFaint
                : .added(pages: pagesRecognised, skipped: pagesSkipped))
    }
}

/// The OCR seam the queue's job body is written against (mirrors `Compressing`): recognition and
/// delivery are separate steps because one recognition serves **every** variant the job ships.
protocol OCRing: Sendable {
    func recognise(_ input: URL, options: OCROptions,
                   progress: @escaping (Double) -> Void) async throws -> RecognisedDocument
    func append(_ recognised: RecognisedDocument, to target: URL, output: URL) throws
}

extension OCREngine: OCRing {}

/// Makes image-only PDFs searchable by adding an invisible Vision text layer (spec §6).
///
/// Per page: pages that already carry extractable text are skipped (`PDFService.pageHasText`);
/// image pages are rendered upright at 300 DPI (**per-page render/release** — one raster resident
/// at a time, whatever the page count), recognised with `VisionOCR`, and the results handed to
/// `PDFWriter` to embed. The recognised *text* is not per-page — it accumulates for the whole
/// document until the writer consumes it, which is what `maxRecognisedTextRuns` bounds.
/// Output is written to a temp file **in the output directory** then atomically renamed, and
/// re-validated before success. If every page already had text → `.alreadySearchable`.
///
/// The two halves are separately callable through `OCRing` — `recognise` reads, `append` writes —
/// because one recognition of the original serves every variant a job delivers (spec §6.4).
/// `ocr(_:to:options:progress:)` is exactly those two steps plus the atomic delivery.
struct OCREngine {
    /// Render resolution for OCR. 300 DPI is the spec default (corpus-tunable); it is a single
    /// fixed value today, so it stays a constant rather than a config knob.
    private static let renderDPI: CGFloat = 300

    /// Upper bound on the raster produced for one page.
    ///
    /// `/MediaBox` comes from the untrusted file and the render scales straight off it, so
    /// without a ceiling the allocation is whatever the document asks for: the specification's
    /// own largest legal page, 14400 pt, is 60,000 px a side at 300 DPI — roughly 14 GB for one
    /// page, and a larger declared box grows quadratically from there.
    ///
    /// 40 megapixels renders every page up to about A2 at the full 300 DPI; beyond that the
    /// resolution degrades instead of the memory. Vision gains nothing from a 60,000-px page.
    static let maxRasterPixels: CGFloat = 40_000_000

    /// Upper bound on the recognised text retained for one document.
    ///
    /// The raster is per-page, but the recognised runs are not: every `PositionedText` (a `String`
    /// plus a `CGRect`) stays resident until the writer consumes them, and both the page count and
    /// the density of each page come from the input. Two million runs is roughly 2000 words on
    /// each of a thousand pages — past any honest scan, and already hundreds of megabytes with two
    /// OCR jobs in flight. Past it the file is declined rather than silently truncated: half a
    /// text layer delivered as a success is the outcome §3.7 forbids.
    static let maxRecognisedTextRuns = 2_000_000

    /// The running total of recognised runs, or a throw once the document passes
    /// `maxRecognisedTextRuns`. Split out of the recognition loop so the bound has a test that
    /// exercises it (§4.4) without needing Vision to recognise two million runs.
    static func accumulate(runs: Int, adding boxes: Int) throws -> Int {
        let total = runs + boxes
        guard total <= maxRecognisedTextRuns else { throw OCRError.recognisedTextTooLarge }
        return total
    }

    /// The raster size for a page of `displayed` points at `dpi`, clamped to `maxRasterPixels`,
    /// or nil when the page is degenerate.
    static func rasterSize(displayed: CGSize, dpi: CGFloat) -> CGSize? {
        guard displayed.width > 0, displayed.height > 0,
              displayed.width.isFinite, displayed.height.isFinite else { return nil }
        var scale = dpi / 72.0
        let pixels = displayed.width * scale * displayed.height * scale
        if pixels > maxRasterPixels {
            scale *= (maxRasterPixels / pixels).squareRoot()
        }
        // Round *down*: a ceiling that rounding can step over is not a ceiling.
        let size = CGSize(width: (displayed.width * scale).rounded(.down),
                          height: (displayed.height * scale).rounded(.down))
        guard size.width >= 1, size.height >= 1 else { return nil }
        return size
    }

    let service: PDFService
    let vision: VisionOCR
    let writer: PDFWriter
    let validator: OutputValidator

    init(service: PDFService = PDFService(),
         vision: VisionOCR = VisionOCR(),
         writer: PDFWriter = PDFWriter(),
         validator: OutputValidator = OutputValidator()) {
        self.service = service
        self.vision = vision
        self.writer = writer
        self.validator = validator
    }

    func ocr(_ input: URL,
             to output: URL,
             options: OCROptions,
             progress: @escaping (Double) -> Void) async throws -> RowOutcome {
        let input = input.canonical
        let output = output.canonical
        // Compared the way the filesystem compares, not the way `String` does (§5.2): APFS is
        // case- and normalisation-insensitive by default, and `canonical` can only case-correct a
        // path that already exists — the output does not yet, so `Report.pdf` and `report.pdf`
        // would otherwise pass this guard and the delivery would overwrite the input.
        guard input.path.precomposedStringWithCanonicalMapping.lowercased()
                != output.path.precomposedStringWithCanonicalMapping.lowercased() else {
            throw OCRError.sameInputOutput
        }

        let recognised = try await recognise(input, options: options, progress: progress)
        let outcome = recognised.outcome

        // The row's size facts. This leg compresses nothing, so both start at the input's size —
        // the append genuinely grows the delivered file, and the queue's commit step re-stats it
        // (`RowOutcome.finalBytes`' ownership note) rather than the engine guessing here.
        let inputSize = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // Nothing to deliver, for either of the two reasons recognition can find nothing to add:
        // every page already carried text, or the pages that lacked it recognised no usable run
        // (a blank or unreadable scan). The writer's no-op path would emit a byte-identical
        // duplicate of the input, and handing that back as an OCR result is the misrepresentation
        // §3.7 forbids — so nothing is written and the row says what actually happened.
        if outcome == .alreadySearchable || outcome == .tooFaint {
            return RowOutcome(originalBytes: inputSize, finalBytes: inputSize, ocr: outcome)
        }

        // Temp file in the OUTPUT directory (same volume → atomic rename can't cross-device fail).
        let outputDir = output.deletingLastPathComponent().canonical
        let tempURL = outputDir.appendingPathComponent(".toolbox-\(UUID().uuidString).pdf").canonical
        var renamed = false
        defer { if !renamed { try? FileManager.default.removeItem(at: tempURL) } }

        // The append — writing the incremental update, then reading the whole file back for both
        // validation passes — is synchronous and unbounded, so it runs off the cooperative pool
        // (§6.1); parking a pool thread here would starve every other job.
        try await offloadBlocking { try self.append(recognised, to: input, output: tempURL) }

        // Last thing before the file becomes visible to the user. The only other check is inside
        // the recognition loop, and everything between it and here — writing the incremental
        // update, then two validation passes that re-render pages — is slow enough to cover a
        // whole cancellation. Cancellation is cooperative: unobserved, it does not throw, so
        // without this the user cancels and the output is delivered anyway. `renamed` stays false
        // on the throw, so the `defer` removes the temp and nothing is left behind.
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: tempURL, to: output)
        renamed = true
        progress(1.0)
        return RowOutcome(originalBytes: inputSize, finalBytes: inputSize, ocr: outcome)
    }

    /// Recognise `input`'s image pages — the whole read-only half of the OCR leg, run **once** per
    /// file against the original (spec §6.4: better input than any compressed variant, and the
    /// results serve every variant the job delivers).
    ///
    /// Pages that already carry extractable text are skipped; the rest are rendered upright at
    /// 300 DPI one at a time and handed to Vision. `progress` reports per-page completion.
    func recognise(_ input: URL,
                   options: OCROptions,
                   progress: @escaping (Double) -> Void) async throws -> RecognisedDocument {
        let input = input.canonical

        switch try OpenGuard.inspect(input) {
        case .ok: break
        case .encrypted: throw OCRError.encrypted
        case .corrupt: throw OCRError.corrupt
        }
        guard let doc = PDFDocument(url: input) else { throw OCRError.corrupt }
        let count = doc.pageCount
        guard count > 0 else { throw OCRError.corrupt }

        var pageText: [Int: [PositionedText]] = [:]
        var geometry: [Int: PageGeometry] = [:]
        var skipped = 0
        var ocrPages = 0
        var retainedRuns = 0

        for i in 0..<count {
            try Task.checkCancellation()
            // A page the document counts but cannot materialise is a damaged file (§3.7): skipping
            // it would drop the user's page from both tallies and still report success.
            guard let page = doc.page(at: i) else { throw OCRError.corrupt }
            geometry[i] = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)

            if service.pageHasText(page) {
                skipped += 1                                   // already searchable — leave it (spec §6)
            } else {
                // A page that cannot be rasterised cannot be recognised, so the file is declined
                // (§3.8) — counting it as OCR'd would report work that never happened.
                guard let image = await renderUpright(page, dpi: Self.renderDPI) else {
                    throw OCRError.unrenderablePage(index: i)
                }
                ocrPages += 1
                let boxes = try await vision.recognise(image, options: options)
                if !boxes.isEmpty {
                    retainedRuns = try Self.accumulate(runs: retainedRuns, adding: boxes.count)
                    pageText[i] = boxes
                }
            }
            progress(Double(i + 1) / Double(count))
        }

        return RecognisedDocument(pageText: pageText, geometry: geometry,
                                  pagesRecognised: ocrPages, pagesSkipped: skipped,
                                  pageCount: count)
    }

    /// Write `target` plus `recognised`'s text layer to `output`, by incremental update — the
    /// delivery half of the OCR leg, run once per variant the job ships (spec §6.4). `target` is
    /// only ever read; the caller decides where the result goes.
    ///
    /// **The geometry is derived from `target`, never from `recognised.geometry`.** Vision's boxes
    /// are normalised against the page as *displayed*, so they project onto whatever the target's
    /// own MediaBox and `/Rotate` are: a Rung-1 variant keeps the original geometry and the append
    /// is direct, while an MRC/bilevel composed page carries the original's displayed size at
    /// origin (0,0) with no `/Rotate` — the same fractions, the right way up.
    ///
    /// A target with a different page count is not the document that was recognised, so the runs
    /// would land on the wrong pages: refused before anything is written. Callers consult
    /// `recognised.outcome` first — a recognition with nothing to add writes no file at all, so
    /// this is never asked to append an empty layer.
    func append(_ recognised: RecognisedDocument, to target: URL, output: URL) throws {
        let target = target.canonical
        guard let doc = PDFDocument(url: target) else { throw OCRError.corrupt }
        guard doc.pageCount == recognised.pageCount else { throw OCRError.validationFailed }

        var geometry: [Int: PageGeometry] = [:]
        for index in recognised.pageText.keys {
            guard let page = doc.page(at: index) else { throw OCRError.corrupt }
            geometry[index] = PageGeometry(mediaBox: page.bounds(for: .mediaBox),
                                           rotation: page.rotation)
        }

        try writer.appendTextLayer(to: target, output: output,
                                   pageText: recognised.pageText, geometry: geometry)
        // From here the output exists and is ours: a file that fails the fail-loud net must not be
        // left on disk where the caller asked for a sound one.
        var sound = false
        defer { if !sound { try? FileManager.default.removeItem(at: output) } }
        guard try validator.validate(input: target, output: output) else {
            throw OCRError.validationFailed
        }
        try validateOCROutput(input: target, output: output,
                              textPages: Set(recognised.pageText.keys),
                              pageCount: recognised.pageCount)
        sound = true
    }


    /// OCR-specific fail-loud net, run before the output is ever placed.
    ///
    /// The generic `OutputValidator` samples a few pages and is tuned for lossy compression, where
    /// the output legitimately differs. OCR needs stronger guarantees: it appends to an untrusted
    /// file with a hand-rolled incremental-update writer, and a writer that mis-tokenises can emit
    /// a plausible-looking but structurally corrupt document. Any failure here discards the output
    /// and fails that file — a skipped file is always preferable to a silently corrupt one, and it
    /// is the same visible outcome the object-stream limitation already produces.
    func validateOCROutput(input: URL, output: URL, textPages: Set<Int>, pageCount: Int) throws {
        // 1. The incremental-update invariant, and the strongest check available: the original
        //    file must be the output's verbatim prefix. That proves every original object — and
        //    so every image XObject — is byte-identical, and catches any writer desync that
        //    corrupted the copied region.
        guard try Self.hasVerbatimPrefix(of: input, in: output) else {
            throw OCRError.validationFailed
        }
        // 2. Structure survived the append.
        guard let outDoc = PDFDocument(url: output), outDoc.pageCount == pageCount else {
            throw OCRError.validationFailed
        }
        // 3. Every page we wrote text into must still render AND yield extractable text: rendering
        //    proves the page object still parses, extraction proves the layer actually landed.
        //    Checking all of them (not a sample) is what makes single-page corruption fail loud.
        for i in textPages.sorted() {
            guard let page = outDoc.page(at: i) else { throw OCRError.validationFailed }
            _ = try service.render(page, maxDimension: 200)      // per-page render, then released
            guard !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OCRError.validationFailed
            }
        }
    }

    /// Byte-compares `input` against the head of `output` in bounded chunks — never loads either
    /// file whole, so a large scan cannot blow memory just to be validated.
    static func hasVerbatimPrefix(of input: URL, in output: URL) throws -> Bool {
        let inHandle = try FileHandle(forReadingFrom: input)
        let outHandle = try FileHandle(forReadingFrom: output)
        defer { try? inHandle.close(); try? outHandle.close() }
        let chunkSize = 1 << 20
        while true {
            let expected = try inHandle.read(upToCount: chunkSize) ?? Data()
            if expected.isEmpty { return true }              // consumed the whole original
            // `read(upToCount:)` may return fewer bytes than asked for without being at the end of
            // the file, so a short read is topped up rather than called a mismatch — failing a
            // sound job on an I/O quirk would lose the user the work. Only a read that yields
            // nothing is the end of the output, and an output that ends inside the original region
            // is a genuine mismatch.
            var actual = Data()
            while actual.count < expected.count {
                let chunk = try outHandle.read(upToCount: expected.count - actual.count) ?? Data()
                if chunk.isEmpty { break }
                actual.append(chunk)
            }
            if actual != expected { return false }
        }
    }

    /// Render a page **upright** (rotation applied) at `dpi`, one page at a time. Uses
    /// `PDFPage.thumbnail`, which honours `/Rotate` and produces an exactly-sized raster.
    /// `PDFService.render` also renders upright, but bounds its output by a `maxDimension` long
    /// edge; OCR needs an exact-DPI raster, so it keeps its own DPI-driven path here.
    /// The render runs off the cooperative pool; the `NSImage` is freed before returning.
    private func renderUpright(_ page: PDFPage, dpi: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image: CGImage? = autoreleasepool {
                    let box = page.bounds(for: .mediaBox)
                    let rotation = ((page.rotation % 360) + 360) % 360
                    let displayed = (rotation == 90 || rotation == 270)
                        ? CGSize(width: box.height, height: box.width)
                        : box.size
                    guard let size = Self.rasterSize(displayed: displayed, dpi: dpi) else { return nil }
                    let thumbnail = page.thumbnail(of: size, for: .mediaBox)
                    return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
                continuation.resume(returning: image)
            }
        }
    }
}
