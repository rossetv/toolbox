// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
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

        let indices = PDFService.sampleIndices(count: outputDoc.pageCount,
                                               sample: min(outputDoc.pageCount, samplePages))
        for i in indices {
            guard let outPage = outputDoc.page(at: i),
                  let inPage = inputDoc.page(at: i) else { return false }
            // Per-page render/release. Detect content-loss corruption by comparing ink to the SAME
            // input page, NOT against an absolute floor: a legitimately sparse page (a few lines of
            // text with wide margins) renders below any fixed "blank" threshold yet is valid, so a
            // fixed floor falsely rejects it. Instead: if the input page carried real content and the
            // output kept less than `minRetainedInk` of it, the output lost its content → corrupt.
            let inInk = try Self.inkRatio(service.render(inPage, maxDimension: 800))
            guard inInk >= Self.contentFloor else { continue }   // input had no real content to lose
            let outInk = try Self.inkRatio(service.render(outPage, maxDimension: 800))
            if outInk < inInk * Self.minRetainedInk { return false }
        }
        return true
    }

    /// Ink fraction above which an INPUT page is deemed to carry real content (page-border
    /// anti-aliasing alone renders at ~1%, so the floor sits above it).
    private static let contentFloor = 0.02
    /// The output must retain at least this fraction of the input page's ink; below it, the page
    /// has effectively lost its content (compression corruption). Lossy downsampling preserves the
    /// bulk of a page's ink coverage, so a genuine compressed page stays well above this.
    private static let minRetainedInk = 0.3

    /// Fraction of sampled pixels that carry ink (are not near-white).
    private static func inkRatio(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data else { return 0 }
        let length = CFDataGetLength(data)
        guard let ptr = CFDataGetBytePtr(data), length > 0 else { return 0 }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard bytesPerPixel >= 3 else { return 0 }

        var nonWhite = 0
        var total = 0
        let pixelCount = length / bytesPerPixel
        let stride = max(1, pixelCount / 6000) * bytesPerPixel
        var offset = 0
        while offset + 2 < length {
            let r = Int(ptr[offset]), g = Int(ptr[offset + 1]), b = Int(ptr[offset + 2])
            if r < 245 || g < 245 || b < 245 { nonWhite += 1 }
            total += 1
            offset += stride
        }
        return total > 0 ? Double(nonWhite) / Double(total) : 0
    }
}
