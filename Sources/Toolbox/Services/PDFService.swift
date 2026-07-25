// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import PDFKit

enum PDFServiceError: Error, LocalizedError {
    case cannotOpen
    case pageOutOfRange
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .cannotOpen: return "The PDF could not be opened."
        case .pageOutOfRange: return "The requested page is out of range."
        case .renderFailed: return "The page could not be rendered."
        }
    }
}

/// PDF inspection and rasterisation. Rendering is **per-page render-then-release** (the
/// bitmap is created, used and dropped one page at a time) so a 1000-page scan never holds
/// every page in memory.
struct PDFService {

    func pageCount(_ url: URL) throws -> Int {
        guard let doc = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen }
        return doc.pageCount
    }

    /// Reference resolution and coverage threshold for the raster-page test (see `classify`). A
    /// page whose image XObjects cover ≥ `minScanCoverage` of it at `scanReferenceDPI` is a scan,
    /// even if it also carries a text layer. Corpus separation is wide: true image scans read
    /// ≥ 4.0 (200-DPI single-image pages), born-digital pages that embed a logo/QR/figure read
    /// ≤ 0.14 — so 0.5 sits ~3.5× clear of both, and still admits a scan down to ~70 DPI.
    static let scanReferenceDPI: CGFloat = 100
    static let minScanCoverage = 0.5

    /// Classify by extractable-text coverage over a page sample; image-dominated docs are
    /// scans, split colour vs bilevel by rendering a sample page and testing near-two-tone.
    ///
    /// A page that is a full-page raster is a scan **regardless of any text layer** — an image
    /// scan this app (or another tool) has OCR'd carries text on every page, and counting it as
    /// born-digital on text length alone would route it away from Rung 2 (CCITT) and ship the far
    /// weaker gs result. The image-XObject coverage test separates that raster-behind-text from a
    /// genuine born-digital document, which text length alone cannot.
    func classify(_ url: URL) throws -> PDFContentType {
        guard let doc = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen }
        let count = doc.pageCount
        guard count > 0 else { return .bornDigital }

        let indices = Self.sampleIndices(count: count, sample: min(count, 5))
        var textPages = 0
        var imagePages = 0
        for i in indices {
            guard let page = doc.page(at: i) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isRaster = MRCClassifier.imageXObjectCoverage(of: page, referenceDPI: Self.scanReferenceDPI)
                >= Self.minScanCoverage
            if !isRaster && text.count >= 40 { textPages += 1 } else { imagePages += 1 }
        }
        if textPages > 0 && textPages >= imagePages { return .bornDigital }

        // Judged at 1500 px, not a thumbnail. Whether a page is two-tone is a question about the
        // page, but at low resolution the answer is dominated by the *downsampler*: every glyph
        // shrinks to a few anti-aliased mid-grey pixels, so the measured two-tone fraction climbs
        // steadily with resolution. Measured on the greyscale-scan fixture: 0.893 at 500 px
        // (below the gate — the scan Rung 2 exists for would have been routed away from it),
        // 0.928 at 1000 px, 0.970 at 1500 px. A photo reads ~0.10 at every one of those, so the
        // separation is never in doubt; only the true positives were being lost.
        if let first = indices.first, let page = doc.page(at: first),
           let image = try? render(page, maxDimension: 1500), BilevelScan.isNearBilevel(image) {
            return .scanBilevel
        }
        return .scanColour
    }

    /// Whether a page already carries extractable text.
    ///
    /// Takes the page, not the document: a caller iterating a document holds each `PDFPage`
    /// already, and re-deriving it from the URL costs a full re-parse of the whole file per page
    /// — quadratic on exactly the thousand-page scans this tool exists for.
    func pageHasText(_ page: PDFPage) -> Bool {
        !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func pageHasText(_ url: URL, index: Int) throws -> Bool {
        guard let doc = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen }
        guard index >= 0, index < doc.pageCount, let page = doc.page(at: index) else {
            throw PDFServiceError.pageOutOfRange
        }
        return pageHasText(page)
    }

    /// Render a sample of `pages` pages (first, last and evenly spaced), one at a time.
    func renderSample(_ url: URL, pages: Int) throws -> [CGImage] {
        guard let doc = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen }
        let count = doc.pageCount
        guard count > 0 else { return [] }
        let indices = Self.sampleIndices(count: count, sample: min(count, max(1, pages)))
        var images: [CGImage] = []
        images.reserveCapacity(indices.count)
        for i in indices {
            guard let page = doc.page(at: i) else { continue }
            images.append(try render(page, maxDimension: 1000))
        }
        return images
    }

    /// Rasterise one page **upright** (the page's `/Rotate` baked into the pixels) onto a white
    /// background, bounded by `maxDimension` on its long edge.
    ///
    /// `page.draw(with: .mediaBox)` already applies `/Rotate`, so the raster is oriented exactly as
    /// a viewer shows the page. The one thing that has to follow from that is the canvas aspect: at
    /// 90°/270° the visible page is the media box with width and height swapped, and
    /// `bounds(for: .mediaBox)` does **not** swap them — sizing the canvas from the raw media box
    /// there draws the rotated content into a wrong-aspect bitmap and it clips (empirically, to
    /// fully blank). So the canvas is sized from the *displayed* dimensions. Because the raster is
    /// already upright, every consumer that embeds it (the MRC/bilevel composers) must emit
    /// `/Rotate 0` and a MediaBox at these displayed dimensions — re-stamping the source `/Rotate`
    /// would turn the page a second time.
    func render(_ page: PDFPage, maxDimension: CGFloat) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let swap = rotation == 90 || rotation == 270
        let displayedWidth = swap ? bounds.height : bounds.width
        let displayedHeight = swap ? bounds.width : bounds.height
        // `Int(_:)` traps on a non-finite Double, so a NaN/infinite media box would take the whole
        // app down rather than fail one file (§4.5). The sibling `OCREngine.rasterSize` guards the
        // same input; this is that guard, at the other consumer.
        guard displayedWidth.isFinite, displayedHeight.isFinite else {
            throw PDFServiceError.renderFailed
        }
        let scale = maxDimension / max(displayedWidth, displayedHeight, 1)
        let width = max(1, Int((displayedWidth * scale).rounded()))
        let height = max(1, Int((displayedHeight * scale).rounded()))
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colourSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFServiceError.renderFailed
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { throw PDFServiceError.renderFailed }
        return image
    }

    // MARK: helpers

    /// At most `sample` page indices, evenly spaced, including the first and last page whenever
    /// `sample` allows both (a one-page sample is the first page). Never returns more than asked
    /// for: callers size buffers and render budgets from the count.
    static func sampleIndices(count: Int, sample: Int) -> [Int] {
        guard count > 0, sample > 0 else { return [] }
        if sample >= count { return Array(0..<count) }
        guard sample >= 2 else { return [0] }   // the seed pair below is already two indices
        var set: Set<Int> = [0, count - 1]
        let step = max(1, count / sample)
        var i = 0
        while i < count && set.count < sample {
            set.insert(i)
            i += step
        }
        return set.sorted()
    }
}
