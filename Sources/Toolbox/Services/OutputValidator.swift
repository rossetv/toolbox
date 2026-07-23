// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import PDFKit

/// Re-validates a compressed/OCR'd output before it is called done (spec §5.4). Asserts the
/// output opens, has the **same page count** as the input, and that N sample pages **render
/// without error and are non-blank** — catching blank-page / stream corruption that "it opens"
/// alone would miss. It does **not** pixel-compare against the input: lossy compression
/// legitimately changes appearance.
struct OutputValidator {
    let service: PDFService

    init(service: PDFService = PDFService()) {
        self.service = service
    }

    func validate(input: URL, output: URL, samplePages: Int = 3) throws -> Bool {
        guard let inputDoc = PDFDocument(url: input),
              let outputDoc = PDFDocument(url: output) else {
            return false
        }
        guard outputDoc.pageCount > 0, outputDoc.pageCount == inputDoc.pageCount else {
            return false
        }

        // Returns how many of `indices` actually carried content to compare (see the loop body),
        // and whether every one of those comparisons passed.
        func check(_ indices: [Int]) throws -> (compared: Int, ok: Bool) {
            var compared = 0
            for i in indices {
                guard let outPage = outputDoc.page(at: i),
                      let inPage = inputDoc.page(at: i) else { return (compared, false) }
                // Per-page render/release. Detect content-loss corruption by comparing ink to the
                // SAME input page, NOT against an absolute floor: a legitimately sparse page (a
                // few lines of text with wide margins) renders below any fixed "blank" threshold
                // yet is valid, so a fixed floor falsely rejects it. Instead: if the input page
                // carried real content and the output kept less than `minRetainedInk` of it, the
                // output lost its content → corrupt.
                let inInk = try Self.inkRatio(service.render(inPage, maxDimension: 800))
                guard inInk >= Self.contentFloor else { continue }   // nothing here to lose
                compared += 1
                let outInk = try Self.inkRatio(service.render(outPage, maxDimension: 800))
                if outInk < inInk * Self.minRetainedInk { return (compared, false) }
                // Bounded upwards too. A one-sided floor passes the worst corruption there is: an
                // inverted or ink-flooded page measures near 1.0 and sails through, so any future
                // polarity or bitstream regression would be delivered as a success rather than
                // falling back. Compression never multiplies a page's ink; this only catches damage.
                if outInk > inInk * Self.maxRetainedInk { return (compared, false) }
            }
            return (compared, true)
        }

        let indices = PDFService.sampleIndices(count: outputDoc.pageCount,
                                               sample: min(outputDoc.pageCount, samplePages))
        let (compared, ok) = try check(indices)
        guard ok else { return false }
        if compared > 0 { return true }

        // Every sampled INPUT page rendered below the content floor: `.sampleIndices` always
        // includes just the first and last page, so a document whose only real content sits
        // strictly between them can reach here with no content signal at all — "opens + same
        // page count" is not proof of anything. Widen to the whole document before passing: a
        // document that is genuinely blank throughout (no comparable page anywhere) still passes,
        // but real content hiding outside the narrow sample gets its chance to be checked.
        guard indices.count < outputDoc.pageCount else { return true }   // already checked everything
        let (_, wideOk) = try check(Array(0..<outputDoc.pageCount))
        return wideOk
    }

    /// Ink fraction above which an INPUT page is deemed to carry real content. With row padding
    /// no longer miscounted (see `inkRatio`), a truly empty page measures 0.0, so this sits just
    /// above zero: measured fixtures are blank 0.0, sparse scan 0.020, text page 0.086, photo 0.90.
    private static let contentFloor = 0.005
    /// The output must retain at least this fraction of the input page's ink; below it, the page
    /// has effectively lost its content (compression corruption). Lossy downsampling preserves the
    /// bulk of a page's ink coverage, so a genuine compressed page stays well above this.
    private static let minRetainedInk = 0.3
    /// The ceiling half of the same test. Deliberately generous — binarising a soft greyscale scan
    /// legitimately thickens strokes — while still an order of magnitude below an inversion, which
    /// turns a sparse page's ink ratio from roughly 0.02 to roughly 0.98.
    private static let maxRetainedInk = 3.0

    /// Fraction of sampled pixels that carry ink (are not near-white).
    ///
    /// Rows are addressed via `bytesPerRow` and sampled only across the real `width`. A CGImage
    /// row is padded to an alignment boundary (measured here: 2496 vs 618×4 = 2472, i.e. 24 bytes
    /// a row), and those padding bytes are zero — walking the buffer flat reads them as black and
    /// counts them as ink. That inflated every ratio by roughly the padding fraction (~1%), which
    /// is the same order as a blank page's true ink, blinding the blank-page check completely.
    private static func inkRatio(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 0 }
        let length = CFDataGetLength(data)
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let width = image.width, height = image.height, rowBytes = image.bytesPerRow
        guard bytesPerPixel >= 3, length > 0, width > 0, height > 0,
              rowBytes >= width * bytesPerPixel else { return 0 }

        // Sample on a square grid so roughly `target` pixels are inspected regardless of size.
        let target = 6000
        let step = max(1, Int((Double(width) * Double(height) / Double(target)).squareRoot()))
        var nonWhite = 0
        var total = 0
        var y = 0
        while y < height {
            let rowStart = y * rowBytes
            var x = 0
            while x < width {
                let o = rowStart + x * bytesPerPixel
                guard o + 2 < length else { break }
                if Int(ptr[o]) < 245 || Int(ptr[o + 1]) < 245 || Int(ptr[o + 2]) < 245 { nonWhite += 1 }
                total += 1
                x += step
            }
            y += step
        }
        return total > 0 ? Double(nonWhite) / Double(total) : 0
    }
}
